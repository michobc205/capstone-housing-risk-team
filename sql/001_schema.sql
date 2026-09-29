CREATE TABLE IF NOT EXISTS zhvi_monthly (
    county_fips   TEXT NOT NULL,
    month         DATE NOT NULL,
    zhvi          DOUBLE PRECISION,
    region_name   TEXT,
    state         TEXT,
    PRIMARY KEY (county_fips, month)
);

CREATE TABLE IF NOT EXISTS mortgage_monthly (
    month           DATE NOT NULL,
    mortgage_rate   DOUBLE PRECISION,
    PRIMARY KEY (month)
);
