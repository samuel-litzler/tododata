import os
import re
import requests
import subprocess
import logging
from bs4 import BeautifulSoup
from datetime import datetime
import psycopg2
from psycopg2 import sql

# Configuration de la base de données
DB_CONFIG = {
    'host': 'localhost',  # Remplacez par votre hôte PostgreSQL
    'dbname': 'historique_cadastre',
    'user': 'postgres',
    'password': 'postgres',  # Remplacez par votre mot de passe PostgreSQL
}

# URL de base pour les contours administratifs
BASE_URL = "https://etalab-datasets.geo.data.gouv.fr/contours-administratifs/"

# Dossier temporaire pour télécharger les fichiers
TEMP_FOLDER = "temp_files"

# Configuration du logging
logging.basicConfig(level=logging.INFO)
error_logger = logging.getLogger("error_logger")

# Fonction pour créer le schéma si nécessaire
def create_schema(schema_name):
    """Crée un schéma dans PostgreSQL si celui-ci n'existe pas."""
    try:
        with psycopg2.connect(**DB_CONFIG) as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema_name))
                )
                logging.info(f"Schéma {schema_name} créé ou déjà existant.")
    except Exception as e:
        error_logger.error(f"Erreur lors de la création du schéma {schema_name}: {e}")
        raise

# Fonction pour scraper les millésimes disponibles
def get_versions(base_url):
    """Scrape les versions disponibles depuis l'URL."""
    try:
        response = requests.get(base_url)
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')

        versions = []
        for link in soup.find_all('a', href=True):
            if re.match(r'^\d{4}/$', link['href']):
                versions.append(link['href'].strip('/'))
        return versions
    except Exception as e:
        error_logger.error(f"Erreur lors du scraping des millésimes: {e}")
        return []

# Fonction pour télécharger les fichiers 5m.geojson
def download_file(version, filename):
    """Télécharge un fichier GeoJSON pour un millésime donné."""
    file_url = f"{BASE_URL}{version}/geojson/{filename}"
    local_path = os.path.join(TEMP_FOLDER, filename)
    try:
        response = requests.get(file_url, stream=True)
        response.raise_for_status()
        os.makedirs(TEMP_FOLDER, exist_ok=True)
        with open(local_path, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
        logging.info(f"Téléchargé: {file_url}")
        return local_path
    except Exception as e:
        error_logger.error(f"Erreur lors du téléchargement de {file_url}: {e}")
        return None

# Fonction pour importer les fichiers dans PostgreSQL
def load_data_with_ogr2ogr(file_path, schema_name, table_name):
    """Importer des données GeoJSON vers PostgreSQL avec ogr2ogr."""
    command = [
        "ogr2ogr",
        "-f", "PostgreSQL",
        f"PG:host={DB_CONFIG['host']} dbname={DB_CONFIG['dbname']} user={DB_CONFIG['user']} password={DB_CONFIG['password']}",
        file_path,
        "-nln", f"{schema_name}.{table_name}",
        "-overwrite",
    ]
    try:
        subprocess.run(command, check=True)
        logging.info(f"Données importées dans {schema_name}.{table_name}")
    except subprocess.CalledProcessError as e:
        error_logger.error(f"Erreur lors de l'importation avec ogr2ogr: {e}")
        raise

# Fonction principale
def process_versions():
    """Télécharge et importe les fichiers pour chaque millésime."""
    schema_name = "contours_administratifs_historique"
    create_schema(schema_name)  # Création du schéma si nécessaire
    versions = get_versions(BASE_URL)
    
    if not versions:
        logging.error("Aucune version disponible.")
        return

    for version in versions:
        logging.info(f"Traitement de la version {version}")
        filenames = [
            "communes-5m.geojson",
            "departements-5m.geojson",
            "regions-5m.geojson",
            "epci-5m.geojson",
            "mairies.geojson",
            "communes-associees-deleguees-5m.geojson",
        ]
        
        for filename in filenames:
            local_path = download_file(version, filename)
            if local_path:
                table_name = f"{filename.split('.')[0].replace('-', '_')}_{version}"
                load_data_with_ogr2ogr(local_path, schema_name, table_name)
                os.remove(local_path)  # Suppression du fichier temporaire
                logging.info(f"Fichier temporaire supprimé: {local_path}")

# Exécution
if __name__ == "__main__":
    process_versions()
