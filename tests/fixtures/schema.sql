-- Synthetic test schema. No real or customer data.
-- Exercises the object types a logical backup must carry: stored and virtual
-- generated columns (including a STORED generated column used in a UNIQUE
-- key, the pattern that breaks MariaDB-client dumps restored into MySQL with
-- ERROR 3105), JSON, BLOB, utf8mb4, DECIMAL, fractional timestamps, foreign
-- keys, a view, triggers, a procedure, a function and an event.

SET NAMES utf8mb4;

CREATE TABLE widget (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  sku           VARCHAR(32)  NOT NULL,
  label         VARCHAR(200) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL,
  price         DECIMAL(12,4) NOT NULL DEFAULT 0,
  is_active     TINYINT(1) NOT NULL DEFAULT 1,
  -- one active row per SKU: NULL for inactive rows does not collide
  active_marker TINYINT AS (IF(is_active = 1, 1, NULL)) STORED,
  label_upper   VARCHAR(200) AS (UPPER(label)) VIRTUAL,
  attrs         JSON NULL,
  attr_color    VARCHAR(20) AS (JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))) STORED,
  blob_data     BLOB NULL,
  created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_widget_active (sku, active_marker),
  KEY ix_color (attr_color)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE widget_event (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  widget_id  INT UNSIGNED NOT NULL,
  kind       ENUM('created','updated','archived') NOT NULL,
  at         TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  CONSTRAINT fk_event_widget FOREIGN KEY (widget_id) REFERENCES widget (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE audit_counter (
  name  VARCHAR(40) NOT NULL PRIMARY KEY,
  value BIGINT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE VIEW active_widget AS
  SELECT id, sku, label, price, attr_color FROM widget WHERE is_active = 1;

DELIMITER //
CREATE TRIGGER trg_widget_ai AFTER INSERT ON widget FOR EACH ROW
BEGIN
  INSERT INTO widget_event (widget_id, kind) VALUES (NEW.id, 'created');
END//

CREATE TRIGGER trg_widget_au AFTER UPDATE ON widget FOR EACH ROW
BEGIN
  INSERT INTO widget_event (widget_id, kind)
  VALUES (NEW.id, IF(NEW.is_active = 0 AND OLD.is_active = 1, 'archived', 'updated'));
END//

CREATE FUNCTION price_with_tax(p DECIMAL(12,4), rate DECIMAL(5,4))
  RETURNS DECIMAL(12,4) DETERMINISTIC NO SQL
  RETURN ROUND(p * (1 + rate), 4)//

CREATE PROCEDURE archive_sku(IN p_sku VARCHAR(32))
  MODIFIES SQL DATA
BEGIN
  UPDATE widget SET is_active = 0 WHERE sku = p_sku AND is_active = 1;
  INSERT INTO audit_counter (name, value) VALUES ('archived', 1)
    ON DUPLICATE KEY UPDATE value = value + 1;
END//
DELIMITER ;

CREATE EVENT ev_touch_counter
  ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00'
  DISABLE
  DO INSERT INTO audit_counter (name, value) VALUES ('event', 1)
       ON DUPLICATE KEY UPDATE value = value + 1;

-- Representative data: 5000 widgets with unicode, JSON, binary data.
SET SESSION cte_max_recursion_depth = 10000;
INSERT INTO widget (sku, label, price, is_active, attrs, blob_data)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000)
SELECT CONCAT('SKU-', LPAD(n DIV 2, 5, '0')),
       CONCAT('Widget ', n, ' ', ELT(1 + n % 4, 'plain', 'café', 'Ωmega', '🚀 rocket')),
       n * 1.2345,
       n % 2,                                 -- pairs share a SKU; one active, one not
       JSON_OBJECT('color', ELT(1 + n % 3, 'red', 'green', 'blue'), 'n', n),
       UNHEX(SHA2(CONCAT('blob', n), 256))
FROM seq;

CALL archive_sku('SKU-00007');
INSERT INTO audit_counter (name, value) VALUES ('seed', 42);
