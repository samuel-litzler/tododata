import os
import json
import gzip
import psycopg2
from psycopg2 import sql
from concurrent.futures import ThreadPoolExecutor, as_completed
import subprocess
import logging
import threading
from datetime import datetime

# Configuration de la base de données PostgreSQL
DB_CONFIG = {
    "dbname": "historique_cadastre",
    "user": "postgres",
    "password": "postgres",
    "host": "localhost",
    "port": "5432"
}

# Chemins des répertoires
DATA_DIR = "cadastre/data"
LOG_DIR = "cadastre/logs"
os.makedirs(LOG_DIR, exist_ok=True)

# Configuration du logger principal
execution_date = datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
logging.basicConfig(
    filename=os.path.join(LOG_DIR, "all_log_" + execution_date + ".log"),
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)

# Logger pour les erreurs
error_logger = logging.getLogger("error_logger")
error_handler = logging.FileHandler(os.path.join(LOG_DIR, "errors_" + execution_date + ".log"))
error_handler.setLevel(logging.ERROR)
error_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
error_logger.addHandler(error_handler)

# Connexion à PostgreSQL
def connect_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        error_logger.error(f"Erreur lors de la connexion à la base de données : {e}")
        return None

def create_schema(conn, schema_name):
    """Créer un schéma pour chaque millésime"""
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema_name)))
            logging.info(f"Schéma {schema_name} créé.")
    except Exception as e:
        error_logger.error(f"Erreur lors de la création du schéma {schema_name}: {e}")

def detect_column_types(file_path):
    """Détecter les colonnes et leurs types depuis un GeoJSON"""
    try :
        with open(file_path, 'r') as f:
            data = json.load(f)
    except Exception as e:
        error_logger.error(f"Erreur lors de la lecture du fichier {file_path}: {e}")
        raise

    columns = {}
    for feature in data["features"]:
        for key, value in feature["properties"].items():
            col_name = key.lower()
            if col_name not in columns:
                if isinstance(value, int):
                    columns[col_name] = "INTEGER"
                elif isinstance(value, float):
                    columns[col_name] = "DOUBLE PRECISION"
                elif isinstance(value, str):
                    columns[col_name] = "CHARACTER VARYING"
                elif isinstance(value, bool):
                    columns[col_name] = "BOOLEAN"
                else:
                    columns[col_name] = "CHARACTER VARYING"  # Default type

    return columns

def create_table_dynamic(conn, schema_name, table_name, columns):
    """Créer une table PostgreSQL avec des colonnes dynamiques"""
    column_definitions = ", ".join([f"{name} {data_type}" for name, data_type in columns.items()])
    query = f"""
        CREATE TABLE IF NOT EXISTS {schema_name}.{table_name} (
            {column_definitions},
            geom GEOMETRY(Geometry, 4326)
        )
    """
    try:
        with conn.cursor() as cursor:
            cursor.execute(query)
            logging.info(f"Table {table_name} créée avec succès dans le schéma {schema_name}.")
    except Exception as e:
        error_logger.error(f"Erreur lors de la création de la table {table_name}: {e}")

def decompress_gz(file_path):
    """Décompresser un fichier .gz et retourner le chemin du fichier décompressé"""
    if not validate_gz_file(file_path):
        raise ValueError(f"Fichier corrompu ou invalide : {file_path}")
    
    temp_file_path = file_path.replace(".gz", "")
    try:
        with gzip.open(file_path, 'rt', encoding='utf-8') as gz_file:
            with open(temp_file_path, 'w', encoding='utf-8') as json_file:
                json_file.write(gz_file.read())
        logging.info(f"Fichier décompressé : {file_path}")
        return temp_file_path
    except Exception as e:
        error_logger.error(f"Erreur lors de la décompression du fichier {file_path}: {e}")
        raise

def validate_gz_file(file_path):
    """Valide l'intégrité d'un fichier .gz en tentant une lecture rapide"""
    error_logger = logging.getLogger("error_logger")
    try:
        with gzip.open(file_path, 'rb') as gz_file:
            gz_file.read(1)  # Lire un octet pour valider
        return True
    except (OSError, gzip.BadGzipFile) as e:
        error_logger.error(f"Fichier .gz corrompu ou invalide : {file_path} - {e}")
        return False

def load_data_with_ogr2ogr(file_path, schema_name, table_name):
    """Importer des données GeoJSON vers PostgreSQL avec ogr2ogr"""
    error_logger = logging.getLogger("error_logger")
    command = [
        "ogr2ogr",
        "-f", "PostgreSQL",
        f"PG:host={DB_CONFIG['host']} dbname={DB_CONFIG['dbname']} user={DB_CONFIG['user']} password={DB_CONFIG['password']}",
        file_path,
        "-nln", f"{schema_name}.{table_name}",
        "-append",
    ]

    try:
        subprocess.run(command, check=True)
        logging.info(f"Données importées dans {schema_name}.{table_name}")
    except subprocess.CalledProcessError as e:
        error_logger.error(f"Erreur lors de l'importation avec ogr2ogr pour {file_path}: {e}")
        raise

def validate_json(file_path):
    """Valide que le fichier contient un JSON correct avec des features valides"""
    error_logger = logging.getLogger("error_logger")
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        # Vérification de la clé "features" et qu'elle n'est pas vide ou nulle
        if not data.get("features"):
            error_logger.error(f"Fichier invalide : Aucun feature trouvé dans {file_path}")
            return False

        return True
    except json.JSONDecodeError as e:
        error_logger.error(f"Fichier JSON invalide : {file_path} - {e}")
        return False
    except Exception as e:
        error_logger.error(f"Erreur inattendue lors de la validation du JSON {file_path}: {e}")
        return False

def process_file(millesime, department, file_name, conn, logger):
    """Traitement individuel d'un fichier avec verrouillage par fichier"""
    file_path = os.path.join(DATA_DIR, millesime, department, file_name)
    lock_file_path = file_path + ".lock"  # Fichier de verrou temporaire
    schema_name = f"cadastre_{millesime.replace('-', '_')}"
    table_name = f"{file_name.split('-')[-1].replace('.json.gz', '')}_{department}"
    error_logger = logging.getLogger("error_logger")
    # Vérification et création du fichier de verrou
    if os.path.exists(lock_file_path):
        logger.info(f"Fichier déjà en cours de traitement : {file_name}")
        return
    try:
        with open(lock_file_path, 'w') as lock_file:
            lock_file.write("processing")

        logger.info(f"Début du traitement : Département={department}, Fichier={file_name}")

        # Décompression
        decompressed_file_path = decompress_gz(file_path)
        logger.info(f"Fichier décompressé : {file_name}")

        # Vérification que le fichier n'a pas un feature vide
        if not validate_json(decompressed_file_path):
            raise ValueError(f"Fichier JSON invalide ou vide : {decompressed_file_path}")

        # Détection des colonnes et création de la table
        columns = detect_column_types(decompressed_file_path)
        create_table_dynamic(conn, schema_name, table_name, columns)
        logger.info(f"Table {table_name} créée avec succès dans le schéma {schema_name}")

        # Importation avec ogr2ogr
        load_data_with_ogr2ogr(decompressed_file_path, schema_name, table_name)
        logger.info(f"Données importées dans {schema_name}.{table_name}")

        # Supprimer le fichier temporaire
        os.remove(decompressed_file_path)
        logger.info(f"Fichier traité avec succès : {file_name}")
    except ValueError as ve:
        error_logger.error(f"Fichier corrompu ou invalide : {file_name} - {ve}")
    except Exception as e:
        error_logger.error(f"Erreur lors du traitement du fichier {file_name}: {e}")
    finally:
        # Supprimer le fichier de verrou
        if os.path.exists(lock_file_path):
            os.remove(lock_file_path)

def process_millesime(millesime, conn, max_workers=10):
    """Traitement des fichiers d'un millésime avec 10 workers"""
    logger = setup_logger_for_millesime(millesime)
    logger.info(f"Début du traitement du millésime : {millesime}")
    logger_error = logging.getLogger("error_logger")
    schema_name = f"cadastre_{millesime.replace('-', '_')}"
    create_schema(conn, schema_name)

    millesime_path = os.path.join(DATA_DIR, millesime)
    if not os.path.isdir(millesime_path):
        logger_error.warning(f"Répertoire introuvable pour le millésime {millesime}")
        return

    tasks = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        for department in os.listdir(millesime_path):
            department_path = os.path.join(millesime_path, department)
            for file_name in os.listdir(department_path):
                if file_name.endswith('.json.gz'):
                    logger.info(f"Ajout de la tâche : Département={department}, Fichier={file_name}")
                    tasks.append(executor.submit(process_file, millesime, department, file_name, conn, logger))

        for future in as_completed(tasks):
            try:
                future.result()
            except Exception as e:
                logger_error.error(f"Erreur dans une tâche pour le millésime {millesime}: {e}")

    logger.info(f"Fin du traitement du millésime : {millesime}")
  
def setup_logger_for_millesime(millesime):
    """Configurer un logger distinct pour un millésime"""
    logger = logging.getLogger(f"push_db_{millesime}")
    logger.setLevel(logging.INFO)

    # Créer un handler pour ce millésime
    log_file = os.path.join(LOG_DIR, f"push_db_{millesime}_{execution_date}.log")
    file_handler = logging.FileHandler(log_file)
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - [Thread %(threadName)s] - %(message)s"))

    # Ajouter le handler au logger
    if not logger.handlers:  # Éviter les doublons
        logger.addHandler(file_handler)

    return logger

def process_files_sequentially():
    """Traitement séquentiel des millésimes, avec 10 workers pour chaque"""
    conn = connect_db()
    if not conn:
        return

    millesimes = sorted(os.listdir(DATA_DIR))
    for millesime in millesimes:
        process_millesime(millesime, conn, max_workers=10)

    conn.close()

if __name__ == "__main__":
    process_files_sequentially()
