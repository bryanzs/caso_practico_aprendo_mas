
-- CREACIÓN DE VISTAS

-- Se indica que una persona cuenta una sola vez aunque tenga más de un registro.
-- Se considera utilizar la primera `fecha_alta` de cada `telefono_hash` para deduplicar registros de familias.
CREATE OR REPLACE VIEW v_familias AS
SELECT
    p.telefono_hash,
    FIRST(it.ugel) AS ugel,
    FIRST(it.institucion_id) AS institucion_id,
    FIRST(it.zona) AS zona,
    FIRST(p.grupo_id) AS grupo_id,
    MIN(CAST(p.fecha_alta AS DATE)) AS fecha_alta,
    DATE_TRUNC('week', MIN(p.fecha_alta)::DATE) + INTERVAL 6 DAY AS fin_de_semana -- Calculo el fin de semana según la fecha alta
FROM db.participantes p
JOIN db.grupos g
ON g.grupo_id = p.grupo_id
JOIN db.instituciones it
ON it.institucion_id = g.institucion_id
WHERE p.rol = 'familia'
GROUP BY p.telefono_hash; -- 1023 filas = 1101 (originales) - 48 (docentes) -  30 (telefonos duplicados)

-- Interacciones válidas en hora Lima, con el tipo normalizado y la semana de su actividad.
CREATE OR REPLACE VIEW v_evidencias AS
SELECT
    f.telefono_hash,
    f.ugel,
    f.institucion_id,
    f.zona,
    f.grupo_id,
    i.actividad_id,
    CAST(a.fecha_envio_utc AS TIMESTAMP) - INTERVAL 5 HOUR AS fecha_envio, -- convierto a hora peruana
    a.semana,
    CAST(i.fecha_hora_utc AS TIMESTAMP) - INTERVAL 5 HOUR AS fecha_evidencia, -- convierto a hora peruana
    LOWER(TRIM(i.tipo)) AS tipo,
    DATE_TRUNC('week', (i.fecha_hora_utc::TIMESTAMP - INTERVAL 5 HOUR)::DATE) + INTERVAL 6 DAY AS fin_de_semana,
FROM db.interacciones i
JOIN db.actividades a
ON a.actividad_id = i.actividad_id
JOIN db.participantes p
ON p.participante_id = i.participante_id AND p.rol = 'familia' -- ningún docente envía evidencias, entonces filtro por familia
JOIN v_familias f
ON f.telefono_hash = p.telefono_hash -- vinculo mediante telefono_hash para evitar familias duplicadas
WHERE
    i.fecha_hora_utc::TIMESTAMP - INTERVAL 5 HOUR > a.fecha_envio_utc::TIMESTAMP - INTERVAL 5 HOUR -- valido que las evidencias se envien luego del envío de la actividad
    AND LOWER(TRIM(i.tipo)) in ('foto', 'imagen', 'audio', 'video'); -- 3275 filas

-- calculo de las evidencias por grupo por semana
CREATE OR REPLACE VIEW v_evidencias_semanales AS
WITH evidencias_enviadas AS (
    SELECT
        semana,
        fin_de_semana,
        ugel,
        institucion_id,
        zona,
        grupo_id,
        COUNT(DISTINCT telefono_hash) as evidencias,
    FROM v_evidencias
    GROUP BY semana, fin_de_semana, ugel, institucion_id, zona, grupo_id
    ORDER BY semana, fin_de_semana, ugel, grupo_id
), -- 287 registros, deberían ser 288 = 48 grupos x 6 semanas

grilla AS (
    SELECT
        v_e_s.semana,
        v_e_s.fin_de_semana,
        u_g.ugel,
        u_g.institucion_id,
        u_g.zona,
        u_g.grupo_id,
    FROM (
        SELECT
            semana,
            FIRST(fin_de_semana) AS fin_de_semana
        FROM evidencias_enviadas
        GROUP BY semana
    ) v_e_s
    CROSS JOIN (
        SELECT
            it.ugel,
            it.institucion_id,
            it.zona,
            g.grupo_id
        FROM db.grupos g
        JOIN db.instituciones it
        ON g.institucion_id = it.institucion_id
    ) u_g
) -- 288 registros, se usa para imputar los grupo x semana sin evidencias enviadas

SELECT
    COALESCE(e.semana, g.semana) AS semana,
    COALESCE(e.fin_de_semana, g.fin_de_semana) AS fin_de_semana,
    COALESCE(e.ugel, g.ugel) AS ugel,
    COALESCE(e.institucion_id, g.institucion_id) AS institucion_id,
    COALESCE(e.zona, g.zona) AS zona,
    COALESCE(e.grupo_id, g.grupo_id) AS grupo_id,
    COALESCE(e.evidencias, 0) AS evidencias,
FROM evidencias_enviadas e
FULL JOIN grilla g
ON e.semana = g.semana AND e.ugel = g.ugel AND e.grupo_id = g.grupo_id
ORDER BY semana, ugel, grupo_id; -- 288 registros completos sin nulos

-- Vista de evidencias por grupo por semana con la cantidad de familiares registrados hasta la fecha
CREATE OR REPLACE VIEW v_grupo_semana AS
WITH familias_agrupadas AS (
    SELECT
        fin_de_semana,
        ugel,
        institucion_id,
        zona,
        grupo_id,
        COUNT(*) as registradas, -- cuento las familias registradas por semana
    FROM v_familias
    GROUP BY fin_de_semana, ugel, institucion_id, zona, grupo_id
    ORDER BY fin_de_semana, ugel, grupo_id
),

registros_semanales AS (
    SELECT
        fin_de_semana,
        ugel,
        institucion_id,
        zona,
        grupo_id,
        registradas,
        SUM(registradas) OVER (
            PARTITION BY ugel, grupo_id
            ORDER BY fin_de_semana
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS registradas_acumuladas -- calculo la suma acumulada de familias registradas hasta cada fin de semana
    FROM familias_agrupadas
    ORDER BY fin_de_semana, ugel, grupo_id
),

evidencias_registros AS (
    SELECT
        e_s.semana,
        COALESCE(e_s.fin_de_semana, r_s.fin_de_semana) AS fin_de_semana,
        COALESCE(e_s.ugel, r_s.ugel) AS ugel,
        COALESCE(e_s.institucion_id, r_s.institucion_id) AS institucion_id,
        COALESCE(e_s.zona, r_s.zona) AS zona,
        COALESCE(e_s.grupo_id, r_s.grupo_id) AS grupo_id,
        e_s.evidencias,
        r_s.registradas_acumuladas
    FROM v_evidencias_semanales e_s
    FULL JOIN registros_semanales r_s
    ON e_s.ugel = r_s.ugel AND e_s.grupo_id = r_s.grupo_id AND e_s.fin_de_semana = r_s.fin_de_semana -- unifico las evidencias con las familias registradas
    ORDER BY fin_de_semana, ugel, grupo_id
),

imputado AS (
    SELECT
        * EXCLUDE registradas_acumuladas,
        LAST_VALUE(registradas_acumuladas IGNORE NULLS) OVER (
            PARTITION BY ugel, grupo_id
            ORDER BY fin_de_semana
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )::INT AS registradas -- imputo los nulos con un feed fodward
    FROM evidencias_registros
)

SELECT
    * 
FROM imputado
WHERE semana IS NOT NULL -- filtro solo las 6 semanas del análisis
ORDER BY fin_de_semana, ugel, grupo_id;


-- MÉTRICAS DE PARTICIPACIÓN

-- 1. La tasa de participación semanal por UGEL y en total, para las 6 semanas.
SELECT semana,
    ROUND(100.0 * SUM(evidencias) FILTER (WHERE ugel = 'UGEL A') / SUM(registradas) FILTER (WHERE ugel = 'UGEL A'), 1) AS "UGEL A",
    ROUND(100.0 * SUM(evidencias) FILTER (WHERE ugel = 'UGEL B') / SUM(registradas) FILTER (WHERE ugel = 'UGEL B'), 1) AS "UGEL B",
    ROUND(100.0 * SUM(evidencias) FILTER (WHERE ugel = 'UGEL C') / SUM(registradas) FILTER (WHERE ugel = 'UGEL C'), 1) AS "UGEL C",
    ROUND(100.0 * SUM(evidencias) / SUM(registradas), 1) AS "Total"
FROM v_grupo_semana
GROUP BY semana
ORDER BY semana;

-- ----------------------------------------------------------------------------


-- 2. Los 5 grupos con mayor caída de participación entre el promedio de las semanas 1 a 4 y el promedio de las semanas 5 y 6.
WITH tasa_grupo AS (
    SELECT
        grupo_id, ugel, institucion_id, zona,
        semana, 100.0 * evidencias / registradas AS tasa
    FROM v_grupo_semana
)
           
SELECT
    grupo_id, ugel, institucion_id, zona,
    ROUND(AVG(tasa) FILTER (WHERE semana BETWEEN 1 AND 4), 1) AS prom_sem_1_4, -- promedio de tasas semanales (sem 1-4)
    ROUND(AVG(tasa) FILTER (WHERE semana IN (5, 6)), 1) AS prom_sem_5_6, -- promedio de tasas semanales (sem 5-6)
    ROUND(AVG(tasa) FILTER (WHERE semana BETWEEN 1 AND 4) - AVG(tasa) FILTER (WHERE semana IN (5, 6)), 1) AS caida_pp -- caida en puntos porcentuales (pp)
FROM tasa_grupo
GROUP BY grupo_id, ugel, institucion_id, zona
ORDER BY AVG(tasa) FILTER (WHERE semana BETWEEN 1 AND 4) - AVG(tasa) FILTER (WHERE semana IN (5, 6)) DESC, grupo_id
LIMIT 5;

-- ----------------------------------------------------------------------------


-- 3. Cuántas famlilias participaron con evidencia en al menos 2 semanas distintas, de las semanas 1 a 4 y no participaron con evidencia en las semanas 5 y 6, y en qué grupos se concentran.

CREATE OR REPLACE VIEW v_abandonan AS
SELECT f.telefono_hash, f.grupo_id, f.ugel, f.zona,
FROM v_familias f
WHERE (SELECT COUNT(DISTINCT e.semana) FROM v_evidencias e
       WHERE e.telefono_hash = f.telefono_hash AND e.semana BETWEEN 1 AND 4) >= 2 -- evidencia en +2 de las primeras 4 semanas 
  AND NOT EXISTS (SELECT 1 FROM v_evidencias e
                  WHERE e.telefono_hash = f.telefono_hash AND e.semana IN (5, 6)); -- sin evidencia en las últimas 2 semanas


-- Total de familias que dejan de participar
SELECT COUNT(*) AS familias_que_dejan_de_participar FROM v_abandonan; -- 144 familias


-- Detalle de familias que dejan de participar
SELECT
    a.grupo_id, a.ugel, a.zona,
    COUNT(*) AS familias,
    (SELECT COUNT(*) FROM v_familias f WHERE f.grupo_id = a.grupo_id) AS familias_grupo,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM v_familias f WHERE f.grupo_id = a.grupo_id), 1) AS pct_del_grupo
FROM v_abandonan a
GROUP BY a.grupo_id, a.ugel, a.zona,
ORDER BY familias DESC, a.grupo_id;

-- ----------------------------------------------------------------------------


-- 4. Consultas de control de calidad que cuantifiquen los problemas que encuentres en los datos.

-- `telefono_hash` repetidos
-- Detalle de repetidos:
SELECT p.*
FROM db.participantes p
JOIN (SELECT telefono_hash, COUNT(*) AS n FROM db.participantes GROUP BY telefono_hash HAVING COUNT(*) > 1) r
ON p.telefono_hash = r.telefono_hash
ORDER BY telefono_hash, fecha_alta

-- Cantidad de repetidos:
SELECT
    COUNT(*) AS telefonos_repetidos,
    SUM(n) - COUNT(*) AS filas_sobrantes
FROM (SELECT
        telefono_hash,
        COUNT(*) AS n
      FROM db.participantes
      GROUP BY telefono_hash
      HAVING COUNT(*) > 1);

-- ----------------------------------------------------------------------------


-- Familias que participan sin registrarse
SELECT COUNT(*) AS interacciones_totales,
       COUNT(DISTINCT participante_id) AS familias_no_registrados,
       COUNT(*) FILTER (WHERE LOWER(TRIM(tipo)) IN ('foto','imagen','audio','video')) AS interacciones_con_evidencia
FROM db.interacciones
WHERE participante_id NOT IN (SELECT participante_id FROM db.participantes);

-- ----------------------------------------------------------------------------


-- Interacciones duplicadas
SELECT COUNT(*) AS interacciones_duplicadas
FROM (SELECT ROW_NUMBER() OVER (PARTITION BY participante_id, actividad_id, fecha_hora_utc, tipo
                                ORDER BY interaccion_id) AS rn
      FROM db.interacciones)
WHERE rn > 1;

-- ----------------------------------------------------------------------------


-- Tipos de interacciones sin normalizar
SELECT tipo, LENGTH(tipo) AS largo, COUNT(*) AS filas,
       LOWER(TRIM(tipo)) AS normalizado
FROM db.interacciones
GROUP BY tipo
ORDER BY filas DESC;

-- ----------------------------------------------------------------------------


-- Evidencias antes del envío de la actividad
SELECT
    f.telefono_hash,
    f.ugel,
    f.institucion_id,
    f.zona,
    f.grupo_id,
    i.actividad_id,
    CAST(a.fecha_envio_utc AS TIMESTAMP) - INTERVAL 5 HOUR AS fecha_envio,
    a.semana,
    CAST(i.fecha_hora_utc AS TIMESTAMP) - INTERVAL 5 HOUR AS fecha_evidencia,
    LOWER(TRIM(i.tipo)) AS tipo,
    DATE_TRUNC('week', (i.fecha_hora_utc::TIMESTAMP - INTERVAL 5 HOUR)::DATE) + INTERVAL 6 DAY AS fin_de_semana,
FROM db.interacciones i
JOIN db.actividades a
ON a.actividad_id = i.actividad_id
JOIN db.participantes p
ON p.participante_id = i.participante_id AND p.rol = 'familia'
JOIN v_familias f
ON f.telefono_hash = p.telefono_hash -- 18  filas afectadas (cambié la consulta, revisar)
WHERE
    i.fecha_hora_utc::TIMESTAMP - INTERVAL 5 HOUR < a.fecha_envio_utc::TIMESTAMP - INTERVAL 5 HOUR -- 50 filas afectadas
    AND LOWER(TRIM(i.tipo)) in ('foto', 'imagen', 'audio', 'video');

-- ----------------------------------------------------------------------------


-- Grupos - Actividad sin interacciones
WITH ga AS (
    SELECT
        g.grupo_id,
        i.ugel,
        a.actividad_id,
        a.semana,
        a.fecha_envio_utc
    FROM db.grupos g
    JOIN db.instituciones i USING (institucion_id)
    CROSS JOIN db.actividades a
),

n AS (
    SELECT
        p.grupo_id,
        x.actividad_id,
        COUNT(*) AS filas
    FROM db.interacciones x
    JOIN db.participantes p USING (participante_id)
    GROUP BY ALL
)

SELECT
    ga.semana,
    ga.actividad_id,
    ga.ugel,
    COUNT(*) AS grupos_sin_datos
FROM ga LEFT JOIN n USING (grupo_id, actividad_id)
WHERE n.filas IS NULL
GROUP BY ALL
ORDER BY grupos_sin_datos DESC, ga.actividad_id, ga.ugel;
