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
LOG_FILE = "cadastre/logs/create_commune_unique_by_dep.log"

# Configuration du logger
logging.basicConfig(
    level=logging.INFO,
    filename=LOG_FILE,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

# Génralités
def connect_db():
    """Connexion à la base de donnees PostgreSQL"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        logging.error(f"Erreur de connexion à la base de donnees : {e}")
        return None

def create_tables(conn):
    queries = [
        """
        CREATE SCHEMA IF NOT EXISTS reference;
        """,
        """
        CREATE SCHEMA IF NOT EXISTS historique;
        """,
        """
        CREATE SCHEMA IF NOT EXISTS stats;
        """,
        """
        CREATE TABLE IF NOT EXISTS reference.communes_unique (
            code_commune VARCHAR(5),
            millesime VARCHAR(20),
            code_departement VARCHAR(3) NOT NULL,
            nom_commune VARCHAR(100) NOT NULL,
            created TIMESTAMP,
            updated TIMESTAMP,
            status VARCHAR(255),
            fusioned_to VARCHAR(5),
            geom GEOMETRY(Geometry, 4326),
            PRIMARY KEY (code_commune, millesime)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS historique.communes_changes (
            change_id SERIAL PRIMARY KEY,
            code_commune VARCHAR(5) NOT NULL,
            millesime VARCHAR(20) NOT NULL,
            change_type VARCHAR(255) NOT NULL,
            old_value TEXT,
            new_value TEXT,
            created TIMESTAMP,
            updated TIMESTAMP,
            diff_area_from_previous FLOAT,
            old_geom GEOMETRY(Geometry, 4326),
            new_geom GEOMETRY(Geometry, 4326)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS stats.stats_communes (
            millesime VARCHAR(20),
            code_departement VARCHAR(3),
            nb_communes INTEGER NOT NULL,
            PRIMARY KEY (millesime, code_departement)
        );
        """
    ]
    with conn.cursor() as cursor:
        for query in queries:
            cursor.execute(query)
    logging.info("Tables communes_unique, communes_changes et stats_communes creees ou dejà existantes.")

# Utilitaires

def execute_query_safe(conn, query, fetch_one=False, error_message=None):
    """
    Exécute une requête SQL en toute sécurité avec gestion des erreurs.
    """
    try:
        with conn.cursor() as cursor:
            cursor.execute(query)
            return cursor.fetchone() if fetch_one else cursor.fetchall()
    except Exception as e:
        full_message = f"{error_message}: {e}" if error_message else f"Erreur SQL : {e}"
        logging.error(full_message)
        return None


def compare_and_update(conn, table_name, code_commune, field_name, old_value, new_value, millesime):
    """
    Compare une ancienne valeur avec une nouvelle, met à jour la table cible et enregistre dans l'historique si nécessaire.
    """
    if old_value != new_value:
        update_query = f"""
            UPDATE {table_name}
            SET {field_name} = '{new_value}'
            WHERE code_commune = '{code_commune}';
        """
        history_query = f"""
            INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
            VALUES ('{code_commune}', '{millesime}', '{field_name}_update', '{old_value}', '{new_value}');
        """
        execute_query_safe(conn, update_query, error_message=f"Erreur mise à jour {field_name} pour {code_commune}")
        execute_query_safe(conn, history_query, error_message=f"Erreur historique {field_name} pour {code_commune}")
        logging.info(f"{field_name} mis à jour pour {code_commune} : {old_value} -> {new_value}")
    else:
        logging.info(f"{field_name} non modifié pour {code_commune}.")


def validate_and_compare_geometry(conn, code_commune, current_geom_query, previous_geom_query, millesime, update_table):
    """
    Valide et compare les géométries, enregistre les modifications si nécessaire.
    """
    try:
        diff_query = f"""
            SELECT ST_Area(ST_Transform(ST_Difference(
                ({previous_geom_query}),
                ({current_geom_query})
            ), 2154)) AS diff_area;
        """
        diff_area = execute_query_safe(conn, diff_query, fetch_one=True, error_message=f"Erreur comparant géométries pour {code_commune}")
        diff_area = diff_area[0] if diff_area else -1

        if diff_area > 0:
            update_geom_query = f"""
                UPDATE {update_table}
                SET geom = ({current_geom_query})
                WHERE code_commune = '{code_commune}';
            """
            save_change_query = f"""
                INSERT INTO historique.communes_changes (code_commune, millesime, change_type, diff_area_from_previous, old_geom, new_geom)
                VALUES ('{code_commune}', '{millesime}', 'geom_update', {diff_area}, ({previous_geom_query}), ({current_geom_query}));
            """
            execute_query_safe(conn, update_geom_query, error_message=f"Erreur mise à jour géométrie pour {code_commune}")
            execute_query_safe(conn, save_change_query, error_message=f"Erreur historique géométrie pour {code_commune}")
            logging.info(f"Géométrie mise à jour pour {code_commune} avec différence {diff_area}.")
        elif diff_area == 0:
            logging.info(f"Aucune différence géométrique pour {code_commune}.")
        else:
            logging.warning(f"Géométrie invalide ou comparaison échouée pour {code_commune}.")
    except Exception as e:
        logging.error(f"Erreur validation ou comparaison géométrie pour {code_commune}: {e}")


def handle_missing_commune(conn, code_commune, code_departement, millesime, current_geom_query):
    """
    Gère une commune absente dans le millésime actuel : inactive ou fusionnée.
    """
    search_fusion_query = f"""
        SELECT code_commune
        FROM reference.communes_unique
        WHERE ST_Contains(geom, ST_Centroid(({current_geom_query})))
        AND code_commune != '{code_commune}';
    """
    fusioned_to = execute_query_safe(conn, search_fusion_query, fetch_one=True, error_message=f"Erreur recherche fusion pour {code_commune}")
    if fusioned_to:
        fusioned_to = fusioned_to[0]
        update_fusioned_query = f"""
            UPDATE reference.communes_unique
            SET fusioned_to = '{fusioned_to}'
            WHERE code_commune = '{code_commune}';
        """
        save_change_query = f"""
            INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
            VALUES ('{code_commune}', '{millesime}', 'fusioned_to', NULL, '{fusioned_to}');
        """
        execute_query_safe(conn, update_fusioned_query, error_message=f"Erreur mise à jour fusion {code_commune}")
        execute_query_safe(conn, save_change_query, error_message=f"Erreur historique fusion {code_commune}")
        logging.info(f"{code_commune} fusionnée avec {fusioned_to}.")
    else:
        # Marquer comme inactive
        update_status_query = f"""
            UPDATE reference.communes_unique
            SET status = 'inactive'
            WHERE code_commune = '{code_commune}';
        """
        save_change_query = f"""
            INSERT INTO historique.communes_changes (code_commune, millesime, change_type)
            VALUES ('{code_commune}', '{millesime}', 'inactive');
        """
        execute_query_safe(conn, update_status_query, error_message=f"Erreur mise à jour statut inactif pour {code_commune}")
        execute_query_safe(conn, save_change_query, error_message=f"Erreur historique statut inactif {code_commune}")
        logging.info(f"{code_commune} marqué comme inactive.")


# Traitement principal des communes

def process_communes_by_dep(conn, departement_table_name, millesime, previous_millesime):
    """
    Traite les communes pour un département donné, en comparant les données entre deux millésimes.
    """
    code_departement = departement_table_name.split("_")[-1]

    # Étape 1 : Récupérer les communes actuelles
    current_query = f"""
        SELECT id, COALESCE(nom, 'Nom manquant'), updated::timestamp, ST_MakeValid(geom) AS geom
        FROM cadastre_{millesime}.{departement_table_name};
    """
    current_communes = execute_query_safe(conn, current_query, error_message=f"Erreur récupération communes actuelles pour {code_departement}")

    # Étape 2 : Récupérer les communes précédentes
    if previous_millesime:
        previous_query = f"""
            SELECT code_commune, nom_commune, updated, geom
            FROM reference.communes_unique
            WHERE code_departement = '{code_departement}' AND status = 'active';
        """
        previous_communes = {
            row[0]: {"nom_commune": row[1], "updated": row[2], "geom": row[3]} for row in execute_query_safe(conn, previous_query)
        }
    else:
        previous_communes = {}

    # Étape 3 : Comparaison et traitement des communes actuelles
    for commune in current_communes:
        code_commune, nom_commune, updated, geom = commune
        if code_commune in previous_communes:
            pre_values = previous_communes[code_commune]
            compare_and_update(conn, "reference.communes_unique", code_commune, "nom_commune", pre_values["nom_commune"], nom_commune, millesime)
            compare_and_update(conn, "reference.communes_unique", code_commune, "updated", pre_values["updated"], updated, millesime)

            current_geom_query = f"SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}'"
            previous_geom_query = f"SELECT geom FROM reference.communes_unique WHERE code_commune = '{code_commune}'"
            validate_and_compare_geometry(conn, code_commune, current_geom_query, previous_geom_query, millesime, "reference.communes_unique")
        else:
            # Commune nouvelle
            insert_query = f"""
                INSERT INTO reference.communes_unique (code_commune, code_departement, nom_commune, created, updated, geom)
                VALUES ('{code_commune}', '{code_departement}', '{nom_commune}', NOW(), '{updated}', '{geom}');
            """
            execute_query_safe(conn, insert_query, error_message=f"Erreur insertion nouvelle commune {code_commune}")

    # Étape 4 : Identifier et traiter les communes absentes
    for code_commune, pre_values in previous_communes.items():
        if code_commune not in {row[0] for row in current_communes}:
            current_geom_query = f"SELECT geom FROM reference.communes_unique WHERE code_commune = '{code_commune}'"
            handle_missing_commune(conn, code_commune, code_departement, millesime, current_geom_query)

def process_all_millesimes():
    """Traiter tous les millesimes disponibles"""
    conn = connect_db()
    if not conn:
        return

    create_tables(conn)

    # Recuperer tous les schemas de type cadastre_*
    query_schemas = "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'cadastre_%';"


    with conn.cursor() as cursor:
        cursor.execute(query_schemas)
        schemas = [row[0] for row in cursor.fetchall()]

    # Trier les schemas par date (extraire et trier les millesimes)
    sorted_schemas = sorted(schemas, key=lambda x: x.replace("cadastre_", ""))
    previous_millesime = None
    for schema_name in sorted_schemas:
        millesime = schema_name.replace("cadastre_", "")
        logging.info(f" ===== Traitement du millesime {millesime}")

        # Recuperation des tables communes_*
        query_list_departements_tables = f"""
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = '{schema_name}' AND table_name LIKE 'communes_%';
            """
        with conn.cursor() as cursor:
            cursor.execute(query_list_departements_tables)
            departements_tables = [row[0] for row in cursor.fetchall()]

            
        logging.info(f"       Nombres de tables de communes dans le schema {schema_name} : {len(departements_tables)}")

        for departement_table in departements_tables:
            logging.info(f"       === Traitement dep, table {departement_table} dans le schema {schema_name}")

            process_communes_by_dep(conn, departement_table, millesime, previous_millesime)

            # Mettre à jour le millesime precedent
        previous_millesime = millesime

    conn.close()

if __name__ == "__main__":
    process_all_millesimes()
