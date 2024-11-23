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

def connect_db():
    """Connexion à la base de données PostgreSQL"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        logging.error(f"Erreur de connexion à la base de données : {e}")
        return None

def create_tables(conn):
    """Créer les tables nécessaires pour communes_unique, communes_geom et communes_changes"""
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
            code_commune VARCHAR(5) PRIMARY KEY,
            code_departement VARCHAR(3) NOT NULL,
            nom_commune VARCHAR(100) NOT NULL,
            created TIMESTAMP,
            updated TIMESTAMP
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS historique.communes_geom (
            code_commune VARCHAR(5),
            millesime VARCHAR(20),
            geom GEOMETRY(Geometry, 4326),
            PRIMARY KEY (code_commune, millesime)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS historique.communes_changes (
            change_id SERIAL PRIMARY KEY,
            code_commune VARCHAR(5) NOT NULL,
            millesime VARCHAR(20) NOT NULL,
            change_type VARCHAR(50) NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS stats.stats_communes (
            millesime VARCHAR(20),
            code_departement VARCHAR(3),
            nb_communes INTEGER NOT NULL,
            PRIMARY KEY (millesime, code_departement)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS historique.commune_lifecycle (
            code_commune VARCHAR(5) NOT NULL,
            millesime VARCHAR(20) NOT NULL,
            change_type VARCHAR(50) NOT NULL, -- 'created' ou 'deleted'
            target_commune VARCHAR(5), -- Commune ayant absorbé l'ancienne commune
            source_commune VARCHAR(5), -- Commune source lors d'une création par division
            PRIMARY KEY (code_commune, millesime, change_type)
        );
        """
    ]
    with conn.cursor() as cursor:
        for query in queries:
            cursor.execute(query)
    logging.info("Tables communes_unique, communes_geom, communes_changes et stats_communes créées ou déjà existantes.")

def process_communes(conn, schema_name, millesime):
    """Traiter les données des communes pour un millésime donné"""
    try:
        logging.info(f"Traitement du schéma : {schema_name}")

        # Récupération des tables communes_*
        query_list_tables = f"""
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = '{schema_name}' AND table_name LIKE 'communes_%';
        """
        with conn.cursor() as cursor:
            cursor.execute(query_list_tables)
            tables = [row[0] for row in cursor.fetchall()]

        for table in tables:
            logging.info(f"Traitement de la table {table} dans le schéma {schema_name}")

            # Gérer les données communes_unique
            process_communes_unique(conn, schema_name, table)

            # Gérer les données communes_geom
            process_communes_geom(conn, schema_name, table, millesime)

            # Enregistrer les changements dans communes_changes
            log_changes(conn, schema_name, table, millesime)

            update_stats_communes(conn, schema_name, table, millesime)
    except Exception as e:
        logging.error(f"Erreur lors du traitement du millésime {millesime}: {e}")

def process_communes_unique(conn, schema_name, table):
    """Gérer l'insertion ou la mise à jour des communes_unique et enregistrer les logs appropriés."""
    # Étape 1 : Récupérer les valeurs existantes
    pre_query = f"""
        SELECT code_commune, nom_commune, updated
        FROM reference.communes_unique
        WHERE code_commune IN (SELECT id FROM {schema_name}.{table});
    """
    with conn.cursor() as cursor:
        cursor.execute(pre_query)
        pre_data = {row[0]: {"nom_commune": row[1], "updated": row[2]} for row in cursor.fetchall()}

    # Étape 2 : Exécuter l'UPSERT
    upsert_query = f"""
        INSERT INTO reference.communes_unique (code_commune, code_departement, nom_commune, created, updated)
        SELECT 
            id, 
            LEFT(id, 2), 
            COALESCE(nom, 'Nom manquant'), 
            created::timestamp, 
            updated::timestamp
        FROM {schema_name}.{table}
        ON CONFLICT (code_commune) DO UPDATE
        SET 
            nom_commune = EXCLUDED.nom_commune,
            updated = EXCLUDED.updated;
    """
    with conn.cursor() as cursor:
        cursor.execute(upsert_query)

    # Étape 3 : Récupérer les nouvelles valeurs
    post_query = f"""
        SELECT code_commune, nom_commune, updated
        FROM reference.communes_unique
        WHERE code_commune IN (SELECT id FROM {schema_name}.{table});
    """
    with conn.cursor() as cursor:
        cursor.execute(post_query)
        post_data = {row[0]: {"nom_commune": row[1], "updated": row[2]} for row in cursor.fetchall()}

    # Étape 4 : Comparer les données pour générer des logs
    for code_commune, post_values in post_data.items():
        pre_values = pre_data.get(code_commune, {})
        if not pre_values:
            action = "INSERT"
        elif pre_values["nom_commune"] != post_values["nom_commune"]:
            action = "UPDATE_NAME"
        elif pre_values["updated"] != post_values["updated"]:
            action = "UPDATE_DATE"
        else:
            action = "NO_CHANGE"

        logging.info(f"{action} pour la commune {code_commune}: {post_values}")

def process_communes_geom(conn, schema_name, table, millesime):
    """Gérer l'insertion ou la mise à jour des communes_geom et enregistrer les logs appropriés."""
    # Étape 1 : Récupérer les géométries existantes
    pre_query = f"""
        SELECT code_commune, geom
        FROM historique.communes_geom
        WHERE millesime = '{millesime}' AND code_commune IN (SELECT id FROM {schema_name}.{table});
    """
    with conn.cursor() as cursor:
        cursor.execute(pre_query)
        pre_data = {row[0]: row[1] for row in cursor.fetchall()}

    # Étape 2 : Insérer ou mettre à jour les géométries
    upsert_query = f"""
        INSERT INTO historique.communes_geom (code_commune, millesime, geom)
        SELECT id, '{millesime}', ST_MakeValid(geom)
        FROM {schema_name}.{table}
        WHERE (ST_IsValid(geom) OR ST_IsValid(ST_MakeValid(geom)))
        ON CONFLICT (code_commune, millesime) DO UPDATE
        SET geom = EXCLUDED.geom
        WHERE NOT ST_Equals(historique.communes_geom.geom, EXCLUDED.geom);
    """
    with conn.cursor() as cursor:
        cursor.execute(upsert_query)

    # Étape 3 : Récupérer les nouvelles géométries
    post_query = f"""
        SELECT code_commune, geom
        FROM historique.communes_geom
        WHERE millesime = '{millesime}' AND code_commune IN (SELECT id FROM {schema_name}.{table});
    """
    with conn.cursor() as cursor:
        cursor.execute(post_query)
        post_data = {row[0]: row[1] for row in cursor.fetchall()}

    # Étape 4 : Comparer les données pour générer des logs
    for code_commune, post_geom in post_data.items():
        pre_geom = pre_data.get(code_commune)
        if pre_geom is None:
            action = "INSERT"
        elif not pre_geom.equals(post_geom):  # Utilisez la méthode appropriée pour comparer les géométries
            action = "UPDATE"
        else:
            action = "NO_CHANGE"

        logging.info(f"{action} pour la géométrie de la commune {code_commune} au millésime {millesime}.")


def log_changes(conn, schema_name, table, millesime):
    """Enregistrer les changements dans communes_changes"""
    if is_first_millesime(conn, millesime):
        logging.info(f"Premier millésime détecté ({millesime}). Ignorance des comparaisons historiques.")
        return  # Pas de traitement pour le premier millésime

    # Changement de géométrie
    # Cette requête insère un changement de géométrie dans la table `communes_changes` uniquement
    # si la géométrie de la commune pour le millésime actuel est différente de celle du dernier millésime précédent.
    # La comparaison utilise ST_Equals pour vérifier les différences après normalisation avec ST_MakeValid.

    query_log_geom_changes = f"""
        INSERT INTO historique.communes_changes (code_commune, millesime, change_type)
        SELECT t.id, '{millesime}', 'geom'
        FROM {schema_name}.{table} t
        WHERE EXISTS (
            SELECT 1
            FROM historique.communes_geom g
            WHERE g.code_commune = t.id
            AND TO_DATE(g.millesime, 'YYYY-MM-DD') = (
                SELECT MAX(TO_DATE(g2.millesime, 'YYYY-MM-DD'))
                FROM historique.communes_geom g2
                WHERE g2.code_commune = t.id
                AND TO_DATE(g2.millesime, 'YYYY-MM-DD') < TO_DATE('{millesime}', 'YYYY-MM-DD')
            )
            AND NOT ST_Equals(ST_MakeValid(g.geom), ST_MakeValid(t.geom))
        )
        RETURNING code_commune, millesime, change_type;
    """

    with conn.cursor() as cursor:
        cursor.execute(query_log_geom_changes)
        geom_changes = cursor.fetchall()

        # Log des changements
        for code_commune, millesime, change_type in geom_changes:
            logging.info(f"Changement détecté : {change_type} pour la commune {code_commune} au millésime {millesime}")

    # Changement de nom
    # Cette requête insère un changement de nom dans la table `communes_changes` si le nom de la commune 
    # pour le millésime actuel diffère de celui enregistré dans `communes_unique`. La comparaison est 
    # limitée à la dernière version du millésime précédent, identifiée avec TO_DATE pour une gestion correcte des dates.

    # === Création de nouvelles communes
    query_log_created = f"""
        INSERT INTO historique.commune_lifecycle (code_commune, millesime, change_type)
        SELECT t.id, '{millesime}', 'created'
        FROM {schema_name}.{table} t
        WHERE NOT EXISTS (
            SELECT 1
            FROM historique.communes_geom g
            WHERE g.code_commune = t.id
        )
        ON CONFLICT DO NOTHING
        RETURNING code_commune, millesime, change_type;
    """

    with conn.cursor() as cursor:
        cursor.execute(query_log_created)
        created_logs = cursor.fetchall()

    # Log des nouvelles créations
    for code_commune, millesime, change_type in created_logs:
        logging.info(f"Nouvelle commune détectée : {code_commune}, Millésime : {millesime}, Type : {change_type}")
    
    # === Suppression de communes
    query_log_deleted = f"""
        INSERT INTO historique.commune_lifecycle (code_commune, millesime, change_type)
        SELECT g.code_commune, '{millesime}', 'deleted'
        FROM historique.communes_geom g
        WHERE TO_DATE(g.millesime, 'YYYY-MM-DD') = (
            SELECT MAX(TO_DATE(g2.millesime, 'YYYY-MM-DD'))
            FROM historique.communes_geom g2
            WHERE g2.code_commune = g.code_commune
        )
        AND NOT EXISTS (
            SELECT 1
            FROM {schema_name}.{table} t
            WHERE t.id = g.code_commune
        )
        ON CONFLICT DO NOTHING
        RETURNING code_commune, millesime, change_type;
    """

    with conn.cursor() as cursor:
        cursor.execute(query_log_deleted)
        deleted_logs = cursor.fetchall()

    # Log des suppressions
    for code_commune, millesime, change_type in deleted_logs:
        logging.info(f"Commune supprimée détectée : {code_commune}, Millésime : {millesime}, Type : {change_type}")

     # Absorption de communes
    
    # === Absorption de communes
    query_log_absorbed = f"""
        INSERT INTO historique.commune_lifecycle (code_commune, millesime, change_type, target_commune)
        SELECT g.code_commune, '{millesime}', 'absorbed', t.id
        FROM historique.communes_geom g
        LEFT JOIN {schema_name}.{table} t
        ON ST_Intersects(g.geom, t.geom) AND ST_Area(ST_Intersection(g.geom, t.geom)) > 0.8 * ST_Area(g.geom)
        WHERE TO_DATE(g.millesime, 'YYYY-MM-DD') = (
            SELECT MAX(TO_DATE(g2.millesime, 'YYYY-MM-DD'))
            FROM historique.communes_geom g2
            WHERE g2.code_commune = g.code_commune
        )
        AND NOT EXISTS (
            SELECT 1
            FROM {schema_name}.{table} t
            WHERE t.id = g.code_commune
        )
        ON CONFLICT DO NOTHING
        RETURNING code_commune, millesime, change_type, target_commune;
    """

    with conn.cursor() as cursor:
        cursor.execute(query_log_absorbed)
        absorbed_logs = cursor.fetchall()

    # Log des absorptions
    for code_commune, millesime, change_type, target_commune in absorbed_logs:
        logging.info(f"Commune absorbée : {code_commune}, Millésime : {millesime}, Absorbée par : {target_commune}")

    # === Requête pour détecter les communes créées par division
    query_log_created_from = f"""
        INSERT INTO historique.commune_lifecycle (code_commune, millesime, change_type, source_commune)
        SELECT t.id, '{millesime}', 'created_from', g.code_commune
        FROM {schema_name}.{table} t
        LEFT JOIN historique.communes_geom g
        ON ST_Intersects(t.geom, g.geom) AND ST_Area(ST_Intersection(t.geom, g.geom)) > 0.8 * ST_Area(t.geom)
        WHERE NOT EXISTS (
            SELECT 1
            FROM historique.communes_geom g2
            WHERE g2.code_commune = t.id
        )
        ON CONFLICT DO NOTHING
        RETURNING code_commune, millesime, change_type, source_commune;
    """

    with conn.cursor() as cursor:
        cursor.execute(query_log_created_from)
        created_from_logs = cursor.fetchall()

    # Log des créations par division
    for code_commune, millesime, change_type, source_commune in created_from_logs:
        logging.info(f"Commune créée par division : {code_commune}, Millésime : {millesime}, Source : {source_commune}")

def update_stats_communes(conn, schema_name, table, millesime):
    """Calculer et insérer les statistiques des communes par département pour un millésime donné"""
    
    query_stats = f"""
        INSERT INTO stats.stats_communes (millesime, code_departement, nb_communes)
        SELECT '{millesime}', LEFT(id, 2) AS code_departement, COUNT(*) AS nb_communes
        FROM {schema_name}.{table}
        GROUP BY LEFT(id, 2)
        ON CONFLICT (millesime, code_departement) DO UPDATE
        SET nb_communes = EXCLUDED.nb_communes;
    """
    try:
        with conn.cursor() as cursor:
            cursor.execute(query_stats)
            logging.info(f"Statistiques mises à jour pour le millésime {millesime} et la table {table}.")
    except Exception as e:
        logging.error(f"Erreur lors de la mise à jour des statistiques pour {millesime}: {e}")


def is_first_millesime(conn, millesime):
    """Vérifie si le millésime est le premier enregistré dans communes_geom"""
    query = """
        SELECT COUNT(*) 
        FROM historique.communes_geom 
        WHERE TO_DATE(millesime, 'YYYY-MM-DD') < TO_DATE(%s, 'YYYY-MM-DD');
    """
    with conn.cursor() as cursor:
        cursor.execute(query, (millesime,))
        count = cursor.fetchone()[0]
    return count == 0

def process_all_millesimes():
    """Traiter tous les millésimes disponibles"""
    conn = connect_db()
    if not conn:
        return

    create_tables(conn)

    # Récupérer tous les schémas de type cadastre_*
    query_schemas = "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'cadastre_%';"


    with conn.cursor() as cursor:
        cursor.execute(query_schemas)
        schemas = [row[0] for row in cursor.fetchall()]

    # Trier les schémas par date (extraire et trier les millésimes)
    sorted_schemas = sorted(schemas, key=lambda x: x.replace("cadastre_", ""))

    for schema_name in sorted_schemas:
        millesime = schema_name.replace("cadastre_", "")
        logging.info(f"Traitement du millésime {millesime}")
        process_communes(conn, schema_name, millesime)

    conn.close()

if __name__ == "__main__":
    process_all_millesimes()
