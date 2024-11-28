import pandas as pd
from sqlalchemy import create_engine

# Configuration PostgreSQL
DB_CONFIG = {
    "user": "postgres",
    "password": "password",
    "host": "192.168.1.30",
    "port": 5432,
    "database": "historique_cadastre"
}

# Charger les fichiers CSV
def load_csv(file_path, encoding="utf-8"):
    return pd.read_csv(file_path, encoding=encoding)

# Créer la connexion à PostgreSQL
def create_postgres_connection():
    engine = create_engine(f"postgresql://{DB_CONFIG['user']}:{DB_CONFIG['password']}@{DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}")
    return engine

# Créer les tables nécessaires dans PostgreSQL
def create_tables(engine):
    with engine.connect() as conn:
        conn.execute("""
        CREATE TABLE IF NOT EXISTS communes_actuelles (
            id SERIAL PRIMARY KEY,
            com VARCHAR(5),
            typecom VARCHAR(4),
            ncc VARCHAR(200),
            nccenr VARCHAR(200),
            libelle VARCHAR(200),
            date_debut DATE,
            date_fin DATE,
            reg VARCHAR(2),
            dep VARCHAR(3),
            can VARCHAR(5),
            arr VARCHAR(4),
            compct VARCHAR(5)
        );
        
        CREATE TABLE IF NOT EXISTS evenements_communes (
            id SERIAL PRIMARY KEY,
            mod VARCHAR(2),
            date_eff DATE,
            typecom_av VARCHAR(4),
            com_av VARCHAR(5),
            ncc_av VARCHAR(200),
            typecom_ap VARCHAR(4),
            com_ap VARCHAR(5),
            ncc_ap VARCHAR(200)
        );
        
        CREATE TABLE IF NOT EXISTS communes_historique (
            id SERIAL PRIMARY KEY,
            com VARCHAR(5),
            tncc VARCHAR(1),
            ncc VARCHAR(200),
            nccenr VARCHAR(200),
            libelle VARCHAR(200),
            date_debut DATE,
            date_fin DATE
        );
        """)
        print("Tables created successfully.")

# Insérer les données dans PostgreSQL
def insert_data_to_postgres(engine, table_name, dataframe):
    dataframe.to_sql(table_name, engine, if_exists='append', index=False)
    print(f"Data inserted into {table_name} successfully.")

# Préparer l'historique des communes
def process_communes_historique(engine):
    with engine.connect() as conn:
        conn.execute("""
        CREATE TABLE IF NOT EXISTS communes_full_history AS
        SELECT
            COALESCE(ec.com_ap, hc.com) AS code_insee,
            COALESCE(ec.date_eff, hc.date_debut) AS date_start,
            COALESCE(ec.ncc_ap, hc.ncc) AS name_current,
            hc.date_fin AS date_end,
            ec.mod AS event_type,
            ec.typecom_av AS previous_type,
            ec.com_av AS previous_code,
            ec.ncc_av AS previous_name
        FROM
            communes_historique hc
        FULL OUTER JOIN
            evenements_communes ec
        ON
            hc.com = ec.com_av OR hc.com = ec.com_ap
        ORDER BY code_insee, date_start;
        """)
        print("Historic table `communes_full_history` created.")

# Main function
if __name__ == "__main__":
    # Charger les fichiers CSV
    communes_actuelles = load_csv("cadastre/data/insee/v_commune_2024.csv")
    evenements_communes = load_csv("cadastre/data/insee/v_mvt_commune_2024.csv")
    communes_historique = load_csv("cadastre/data/insee/v_commune_depuis_1943.csv")

    # Créer la connexion PostgreSQL
    engine = create_postgres_connection()

    # Créer les tables
    create_tables(engine)

    # Insérer les données
    insert_data_to_postgres(engine, "communes_actuelles", communes_actuelles)
    insert_data_to_postgres(engine, "evenements_communes", evenements_communes)
    insert_data_to_postgres(engine, "communes_historique", communes_historique)

    # Générer l'historique des communes
    process_communes_historique(engine)
