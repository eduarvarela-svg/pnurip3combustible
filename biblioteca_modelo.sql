-- =====================================================================
--  SISTEMA DE BIBLIOTECA · Práctica 3
--  Motor: MySQL 8.4
--  Autor: (tu nombre)
--  Descripción: usuarios, libros y préstamos, con integridad referencial,
--               control automático de disponibilidad, vistas y datos demo.
-- =====================================================================
SET NAMES utf8mb4;

DROP DATABASE IF EXISTS biblioteca;
CREATE DATABASE biblioteca
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE biblioteca;

-- =====================================================================
--  1. TABLAS
-- =====================================================================

-- ---------------------------------------------------------------------
--  USUARIOS
-- ---------------------------------------------------------------------
CREATE TABLE usuarios (
  id_usuario     INT AUTO_INCREMENT PRIMARY KEY,
  nombre         VARCHAR(100) NOT NULL,
  correo         VARCHAR(120) NOT NULL,
  telefono       VARCHAR(20),
  fecha_registro DATE NOT NULL DEFAULT (CURRENT_DATE),
  activo         TINYINT(1) NOT NULL DEFAULT 1,
  CONSTRAINT uq_usuarios_correo UNIQUE (correo),
  CONSTRAINT chk_usuarios_correo CHECK (correo LIKE '%_@_%._%')
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
--  LIBROS
--  cantidad_disponible se mantiene con triggers (ver sección 3).
-- ---------------------------------------------------------------------
CREATE TABLE libros (
  id_libro             INT AUTO_INCREMENT PRIMARY KEY,
  titulo               VARCHAR(150) NOT NULL,
  autor                VARCHAR(100) NOT NULL,
  isbn                 VARCHAR(20)  NOT NULL,
  categoria            VARCHAR(50),
  editorial            VARCHAR(100),
  anio                 SMALLINT,
  cantidad_total       INT NOT NULL DEFAULT 1,
  cantidad_disponible  INT NOT NULL DEFAULT 1,
  CONSTRAINT uq_libros_isbn UNIQUE (isbn),
  CONSTRAINT chk_libros_total CHECK (cantidad_total >= 0),
  CONSTRAINT chk_libros_disponible
    CHECK (cantidad_disponible >= 0 AND cantidad_disponible <= cantidad_total)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
--  PRÉSTAMOS
--  estado: 'prestado' | 'devuelto'
--  Un préstamo vencido NO es un estado: se calcula con la fecha.
-- ---------------------------------------------------------------------
CREATE TABLE prestamos (
  id_prestamo              INT AUTO_INCREMENT PRIMARY KEY,
  id_usuario               INT NOT NULL,
  id_libro                 INT NOT NULL,
  fecha_prestamo           DATE NOT NULL DEFAULT (CURRENT_DATE),
  fecha_devolucion_esperada DATE NOT NULL,
  fecha_devolucion_real    DATE NULL,
  estado                   ENUM('prestado','devuelto') NOT NULL DEFAULT 'prestado',
  CONSTRAINT fk_prestamos_usuario
    FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_prestamos_libro
    FOREIGN KEY (id_libro) REFERENCES libros(id_libro)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_prestamos_fechas
    CHECK (fecha_devolucion_esperada >= fecha_prestamo),
  CONSTRAINT chk_prestamos_dev_real
    CHECK (fecha_devolucion_real IS NULL OR fecha_devolucion_real >= fecha_prestamo),
  CONSTRAINT chk_prestamos_estado_dev
    CHECK ( (estado = 'devuelto' AND fecha_devolucion_real IS NOT NULL)
         OR (estado = 'prestado' AND fecha_devolucion_real IS NULL) )
) ENGINE=InnoDB;

-- =====================================================================
--  2. ÍNDICES (búsquedas y reportes)
-- =====================================================================
CREATE INDEX idx_libros_titulo   ON libros (titulo);
CREATE INDEX idx_libros_autor    ON libros (autor);
CREATE INDEX idx_prestamos_usuario ON prestamos (id_usuario);
CREATE INDEX idx_prestamos_libro   ON prestamos (id_libro);
CREATE INDEX idx_prestamos_estado  ON prestamos (estado);
CREATE INDEX idx_prestamos_fechas  ON prestamos (fecha_prestamo, fecha_devolucion_esperada);

-- =====================================================================
--  3. TRIGGERS · CONTROL AUTOMÁTICO DE DISPONIBILIDAD
--     Al prestar: -1 ejemplar. Al devolver/borrar: +1.
-- =====================================================================
DELIMITER $$

CREATE TRIGGER trg_prestamo_insert AFTER INSERT ON prestamos
FOR EACH ROW
BEGIN
  IF NEW.estado = 'prestado' THEN
    UPDATE libros
       SET cantidad_disponible = cantidad_disponible - 1
     WHERE id_libro = NEW.id_libro
       AND cantidad_disponible > 0;
    IF ROW_COUNT() = 0 THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No hay ejemplares disponibles de este libro';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_prestamo_update AFTER UPDATE ON prestamos
FOR EACH ROW
BEGIN
  IF OLD.estado <> NEW.estado THEN
    IF OLD.estado = 'prestado' AND NEW.estado = 'devuelto' THEN
      UPDATE libros
         SET cantidad_disponible = cantidad_disponible + 1
       WHERE id_libro = NEW.id_libro;
    ELSEIF OLD.estado = 'devuelto' AND NEW.estado = 'prestado' THEN
      UPDATE libros
         SET cantidad_disponible = cantidad_disponible - 1
       WHERE id_libro = NEW.id_libro
         AND cantidad_disponible > 0;
      IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'No hay ejemplares disponibles de este libro';
      END IF;
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_prestamo_delete AFTER DELETE ON prestamos
FOR EACH ROW
BEGIN
  IF OLD.estado = 'prestado' THEN
    UPDATE libros
       SET cantidad_disponible = cantidad_disponible + 1
     WHERE id_libro = OLD.id_libro;
  END IF;
END$$

DELIMITER ;

-- =====================================================================
--  4. VISTAS · CONSULTAS FRECUENTES
-- =====================================================================

-- Libros que tienen al menos un ejemplar disponible
CREATE OR REPLACE VIEW v_libros_disponibles AS
SELECT id_libro, titulo, autor, isbn, categoria,
       cantidad_total, cantidad_disponible
FROM libros
WHERE cantidad_disponible > 0;

-- Préstamos activos (no devueltos), con días de atraso
CREATE OR REPLACE VIEW v_prestamos_activos AS
SELECT p.id_prestamo,
       u.id_usuario,
       u.nombre  AS usuario,
       u.correo,
       l.id_libro,
       l.titulo,
       l.isbn,
       p.fecha_prestamo,
       p.fecha_devolucion_esperada,
       DATEDIFF(CURDATE(), p.fecha_devolucion_esperada) AS dias_atraso
FROM prestamos p
JOIN usuarios u ON u.id_usuario = p.id_usuario
JOIN libros   l ON l.id_libro   = p.id_libro
WHERE p.estado = 'prestado';

-- Préstamos vencidos (fecha esperada ya pasó)
CREATE OR REPLACE VIEW v_prestamos_vencidos AS
SELECT *
FROM v_prestamos_activos
WHERE fecha_devolucion_esperada < CURDATE();

-- Historial completo por usuario
CREATE OR REPLACE VIEW v_historial_prestamos AS
SELECT p.id_prestamo,
       CONCAT(u.nombre, ' <', u.correo, '>') AS usuario,
       l.titulo,
       l.isbn,
       p.fecha_prestamo,
       p.fecha_devolucion_esperada,
       p.fecha_devolucion_real,
       p.estado,
       CASE
         WHEN p.estado = 'devuelto' THEN 'Devuelto'
         WHEN p.fecha_devolucion_esperada < CURDATE() THEN 'Vencido'
         ELSE 'En curso'
       END AS situacion
FROM prestamos p
JOIN usuarios u ON u.id_usuario = p.id_usuario
JOIN libros   l ON l.id_libro   = p.id_libro;

-- =====================================================================
--  5. DATOS DE EJEMPLO
-- =====================================================================

INSERT INTO usuarios (nombre, correo, telefono) VALUES
('Ana María García',   'ana.garcia@example.com',   '9876-5432'),
('Luis Alberto Pérez', 'luis.perez@example.com',   '9988-1122'),
('Carla Sofía Méndez', 'carla.mendez@example.com', '9777-3344'),
('Diego Andrés Ramírez','diego.ramirez@example.com','9666-5566'),
('Elena Torres Vega',  'elena.torres@example.com', '9555-7788');

INSERT INTO libros (titulo, autor, isbn, categoria, editorial, anio, cantidad_total, cantidad_disponible) VALUES
('Cien años de soledad',        'Gabriel García Márquez', '978-0307474728', 'Novela',      'Sudamericana', 1967, 3, 3),
('Don Quijote de la Mancha',    'Miguel de Cervantes',    '978-8420412146', 'Clásico',     'Alfaguara',    1605, 2, 2),
('1984',                        'George Orwell',          '978-0451524935', 'Distopía',    'Signet',       1949, 2, 2),
('El Principito',               'Antoine de Saint-Exupéry','978-0156012195','Infantil',    'Harcourt',     1943, 4, 4),
('La Odisea',                   'Homero',                 '978-0140268867', 'Clásico',     'Penguin',     -800, 1, 1),
('Hamlet',                      'William Shakespeare',    '978-0743477123', 'Teatro',      'Simon',        1603, 2, 2),
('Sapiens',                     'Yuval Noah Harari',      '978-0062316097', 'Historia',    'Harper',       2011, 2, 2),
('El arte de la guerra',        'Sun Tzu',                '978-1599869773', 'Estrategia',  'Filiquarian', -500, 1, 1);

-- Préstamos: 5 activos + 1 devuelto
INSERT INTO prestamos
  (id_usuario, id_libro, fecha_prestamo, fecha_devolucion_esperada, fecha_devolucion_real, estado) VALUES
(1, 1, DATE_SUB(CURDATE(), INTERVAL 3 DAY),  DATE_ADD(CURDATE(), INTERVAL 4 DAY),  NULL, 'prestado'),
(2, 2, DATE_SUB(CURDATE(), INTERVAL 12 DAY), DATE_SUB(CURDATE(), INTERVAL 5 DAY),  NULL, 'prestado'),
(3, 3, DATE_SUB(CURDATE(), INTERVAL 20 DAY), DATE_SUB(CURDATE(), INTERVAL 13 DAY), DATE_SUB(CURDATE(), INTERVAL 14 DAY), 'devuelto'),
(4, 4, DATE_SUB(CURDATE(), INTERVAL 2 DAY),  DATE_ADD(CURDATE(), INTERVAL 5 DAY),  NULL, 'prestado'),
(1, 5, DATE_SUB(CURDATE(), INTERVAL 1 DAY),  DATE_ADD(CURDATE(), INTERVAL 10 DAY), NULL, 'prestado'),
(2, 6, CURDATE(),                            DATE_ADD(CURDATE(), INTERVAL 7 DAY),  NULL, 'prestado');

-- =====================================================================
--  6. CONSULTAS DE VERIFICACIÓN
-- =====================================================================

-- 6.1 Todos los libros y su disponibilidad
SELECT id_libro, titulo, autor, cantidad_total, cantidad_disponible
FROM libros ORDER BY titulo;

-- 6.2 Libros disponibles
SELECT * FROM v_libros_disponibles ORDER BY titulo;

-- 6.3 Préstamos activos
SELECT * FROM v_prestamos_activos ORDER BY fecha_devolucion_esperada;

-- 6.4 Préstamos vencidos
SELECT * FROM v_prestamos_vencidos;

-- 6.5 Historial por usuario
SELECT * FROM v_historial_prestamos ORDER BY usuario, fecha_prestamo DESC;

-- 6.6 Usuarios con más préstamos
SELECT u.nombre, COUNT(p.id_prestamo) AS total_prestamos
FROM usuarios u
LEFT JOIN prestamos p ON p.id_usuario = u.id_usuario
GROUP BY u.id_usuario, u.nombre
ORDER BY total_prestamos DESC;

-- 6.7 Libros más prestados
SELECT l.titulo, COUNT(p.id_prestamo) AS veces_prestado
FROM libros l
LEFT JOIN prestamos p ON p.id_libro = l.id_libro
GROUP BY l.id_libro, l.titulo
ORDER BY veces_prestado DESC;

-- =====================================================================
--  7. EJEMPLOS DE OPERACIÓN
-- =====================================================================

-- Registrar un nuevo préstamo (la disponibilidad baja sola por el trigger)
-- INSERT INTO prestamos (id_usuario, id_libro, fecha_devolucion_esperada)
-- VALUES (5, 7, DATE_ADD(CURDATE(), INTERVAL 14 DAY));

-- Registrar una devolución (la disponibilidad sube sola)
-- UPDATE prestamos
--    SET estado = 'devuelto', fecha_devolucion_real = CURDATE()
--  WHERE id_prestamo = 1;

-- =====================================================================
--  FIN
-- =====================================================================
