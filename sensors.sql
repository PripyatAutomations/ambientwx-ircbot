drop table if exists sensor_acl;
drop table if exists available_sensors;

create table sensor_acl (
   acl_id INTEGER PRIMARY KEY AUTOINCREMENT,
   allowed INTEGER DEFAULT 1,
   sensor_name TEXT NOT NULL,
   disabled INTEGER DEFAULT 0
);

CREATE TABLE available_sensors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_id TEXT UNIQUE,
    last_changed TEXT,
    friendly_name TEXT,
    icon TEXT,
    device_class TEXT
);
