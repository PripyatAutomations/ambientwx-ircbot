begin;

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
    state TEXT,
    device_class TEXT
);

insert into sensor_acl (sensor_name) values ('sensor.*_backpack_count');
insert into sensor_acl (sensor_name) values ('sensor.*_bicycle_count');
insert into sensor_acl (sensor_name) values ('sensor.*_car_count');
insert into sensor_acl (sensor_name) values ('sensor.*_cat_count');
insert into sensor_acl (sensor_name) values ('sensor.*_dog_count');
insert into sensor_acl (sensor_name) values ('sensor.*_person_count');

commit;
