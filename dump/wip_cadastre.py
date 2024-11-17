import os
import requests
import logging
from bs4 import BeautifulSoup
import re
import json

# Configuration des chemins et des URL
NEW_BASE_URL = "https://cadastre.data.gouv.fr/data/etalab-cadastre/"
ARCHIVE_BASE_URL = "https://files.data.gouv.fr/cadastre/etalab-cadastre/"
DOWNLOAD_DIR = "cadastre"
LOG_DIR = os.path.join(DOWNLOAD_DIR, "logs")
ANOMALY_DIR = os.path.join(LOG_DIR, "anomalies")
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(ANOMALY_DIR, exist_ok=True)

def setup_logger(version):
    log_filename = os.path.join(LOG_DIR, f"log_{version}.log")
    logger = logging.getLogger(version)
    handler = logging.FileHandler(log_filename, mode='a')
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    handler.setFormatter(formatter)
    
    if logger.hasHandlers():
        logger.handlers.clear()
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)
    
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    return logger

def url_exists(url):
    try:
        response = requests.head(url)
        return response.status_code == 200
    except requests.RequestException:
        return False

def get_latest_versions(base_url):
    try:
        response = requests.get(base_url)
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')
        version_pattern = re.compile(r"\d{4}-\d{2}-\d{2}/")
        return [link['href'].strip('/') for link in soup.find_all('a', href=True) if version_pattern.match(link['href'])]
    except Exception as e:
        logging.error(f"Erreur lors de la récupération des versions : {e}")
        return []

def get_all_versions():
    new_versions = get_latest_versions(NEW_BASE_URL)
    archive_versions = get_latest_versions(ARCHIVE_BASE_URL)
    return sorted(set(new_versions + archive_versions))

def get_departments(version, logger):
    base_urls = [f"{NEW_BASE_URL}{version}/geojson/", f"{ARCHIVE_BASE_URL}{version}/geojson/"]
    for base_url in base_urls:
        if not url_exists(base_url):
            continue
        communes_url = f"{base_url}communes/"
        if not url_exists(communes_url):
            continue
        try:
            response = requests.get(communes_url)
            response.raise_for_status()
            soup = BeautifulSoup(response.content, 'html.parser')
            return [link['href'].strip('/') for link in soup.find_all('a', href=True) if link['href'].strip('/').isdigit()]
        except Exception as e:
            logger.error(f"Erreur lors de la récupération des départements pour {version}: {e}")
    return []

def get_communes(department, version, logger):
    base_urls = [f"{NEW_BASE_URL}{version}/geojson/communes/{department}/", f"{ARCHIVE_BASE_URL}{version}/geojson/communes/{department}/"]
    for base_url in base_urls:
        if not url_exists(base_url):
            continue
        try:
            response = requests.get(base_url)
            response.raise_for_status()
            soup = BeautifulSoup(response.content, 'html.parser')
            return [link['href'].strip('/') for link in soup.find_all('a', href=True) if link['href'].strip('/').isdigit()]
        except Exception as e:
            logger.error(f"Erreur lors de la récupération des communes pour le département {department}: {e}")
    return []

def save_communes_list(version, department, communes):
    """Sauvegarder la liste des communes pour chaque version"""
    os.makedirs(ANOMALY_DIR, exist_ok=True)
    file_path = os.path.join(ANOMALY_DIR, f"{version}_{department}.json")
    with open(file_path, 'w') as f:
        json.dump(communes, f)

def load_communes_list(version, department):
    """Charger la liste des communes d'une version précédente"""
    file_path = os.path.join(ANOMALY_DIR, f"{version}_{department}.json")
    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            return json.load(f)
    return []

def detect_anomalies(current_communes, previous_communes):
    """Détecter les anomalies entre deux listes de communes"""
    added = list(set(current_communes) - set(previous_communes))
    removed = list(set(previous_communes) - set(current_communes))
    return added, removed

def main():
    versions = get_all_versions()
    previous_version = None

    for version in versions:
        logger = setup_logger(version)
        logger.info(f"Traitement de la version : {version}")
        departments = get_departments(version, logger)
        if not departments:
            continue

        for dept in departments:
            logger.info(f"Traitement du département : {dept}")
            current_communes = get_communes(dept, version, logger)
            
            # Charger la liste des communes de la version précédente
            previous_communes = load_communes_list(previous_version, dept) if previous_version else []
            
            # Détecter les anomalies
            added, removed = detect_anomalies(current_communes, previous_communes)
            if added or removed:
                anomaly_report = {
                    "version": version,
                    "department": dept,
                    "added_communes": added,
                    "removed_communes": removed
                }
                report_path = os.path.join(ANOMALY_DIR, f"anomalies_{version}_{dept}.json")
                with open(report_path, 'w') as report_file:
                    json.dump(anomaly_report, report_file, indent=4)
                logger.info(f"Anomalies détectées pour le département {dept}: {anomaly_report}")
            
            # Sauvegarder la liste des communes pour la version actuelle
            save_communes_list(version, dept, current_communes)
        
        previous_version = version

if __name__ == "__main__":
    main()
