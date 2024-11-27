import psycopg2
from psycopg2 import sql
import logging

# Configuration de la base de données PostgreSQL
DB_CONFIG = {
    "dbname": "historique_cadastre",
    "user": "postgres",
    "password": "postgres",
    "host": "192.168.1.30",
    "port": "5432"
}
LOG_FILE = "cadastre/logs/create_commune_unique_by_millesime.log"

# Configuration du logger
logging.basicConfig(
    level=logging.INFO,
    filename=LOG_FILE,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

def connect_db():
    """Connexion à la base de données PostgreSQL."""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        logging.error(f"Erreur de connexion à la base de données : {e}")
        return None

def create_communes_unique_table(conn):
    """Crée la table communes_unique_by_millesime si elle n'existe pas."""
    create_table_query = """
    CREATE TABLE IF NOT EXISTS reference.communes_unique_by_millesime (
        code_commune VARCHAR(5),
        millesime VARCHAR(20),
        code_departement VARCHAR(3),
        nom_commune VARCHAR(100),
        created TIMESTAMP,
        updated TIMESTAMP,
        geom GEOMETRY(Geometry, 4326),
        PRIMARY KEY (code_commune, millesime)
    );
    """
    try:
        with conn.cursor() as cursor:
            cursor.execute(create_table_query)
        logging.info("Table communes_unique_by_millesime créée ou existante.")
    except Exception as e:
        logging.error(f"Erreur création table communes_unique_by_millesime : {e}")

def process_all_millesimes_to_communes_unique(conn):
    """Insère toutes les communes de tous les millésimes dans la table unique."""
    # Récupération de tous les schémas cadastre_{millesime}
    query_schemas = "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'cadastre_%';"
    try:
        with conn.cursor() as cursor:
            cursor.execute(query_schemas)
            schemas = [row[0] for row in cursor.fetchall()]
    except Exception as e:
        logging.error(f"Erreur lors de la récupération des schémas : {e}")
        return

    # Trier les schémas par millésime
    sorted_schemas = sorted(schemas, key=lambda x: x.replace("cadastre_", ""))

    # Parcourir chaque schéma
    for schema_name in sorted_schemas:
        millesime = schema_name.replace("cadastre_", "")
        logging.info(f"Traitement du millésime {millesime}.")

        # Récupération des tables communes_{code_dep} dans le schéma actuel
        query_tables = f"""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = '{schema_name}' AND table_name LIKE 'communes_%';
        """
        try:
            with conn.cursor() as cursor:
                cursor.execute(query_tables)
                departement_tables = [row[0] for row in cursor.fetchall()]
        except Exception as e:
            logging.error(f"Erreur récupération des tables dans le schéma {schema_name} : {e}")
            continue

        # Parcourir chaque table départementale
        for departement_table in departement_tables:
            code_departement = departement_table.split("_")[-1]
            logging.info(f"Traitement de la table {departement_table} dans le schéma {schema_name}.")

            # Insérer les données de la table dans communes_unique_by_millesime
            insert_query = f"""
            INSERT INTO reference.communes_unique_by_millesime (
                code_commune, millesime, code_departement, nom_commune, created, updated, geom
            )
            SELECT
                id AS code_commune,
                '{millesime}' AS millesime,
                '{code_departement}' AS code_departement,
                nom AS nom_commune,
                created::timestamp,
                updated::timestamp,
                ST_MakeValid(geom) AS geom
            FROM {schema_name}.{departement_table};
            """
            try:
                with conn.cursor() as cursor:
                    cursor.execute(insert_query)
                logging.info(f"Données insérées pour {departement_table}, millésime {millesime}.")
            except Exception as e:
                logging.error(f"Erreur commune {departement_table} dans le millésime {millesime} : {e}")

def main():
    conn = connect_db()
    if not conn:
        return

    create_communes_unique_table(conn)
    process_all_millesimes_to_communes_unique(conn)

    conn.close()

if __name__ == "__main__":
    main()
