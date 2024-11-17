import os
import shutil
import argparse
import requests
import json
import logging
from bs4 import BeautifulSoup
import re
from datetime import datetime

# Chemins des répertoires
DOWNLOAD_DIR = "cadastre"
LOG_DIR = os.path.join(DOWNLOAD_DIR, "logs")
ANOMALY_DIR = os.path.join(LOG_DIR, "anomalies")
# === Configuration du script ===
# Configuration du logger
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
# Chemins des fichiers JSON
MILLESIME_VERSIONS_FILE = "millesime_versions.json" # Historique des versions pour chaque millésime, très important pour suivre les changements a chaque exécution du script  
SUMMARY_CHANGES_MILLESIME_VERSIONS_FILE = "summary_changes_millesime_versions.json" # Fichier de résumé des changements pour rapidement voir les modifications, sans avoir à parcourir l'historique

# Chemins des dossiers
SUIVI_DIR = "suivi_fichiers"

NEW_BASE_URL = "https://cadastre.data.gouv.fr/data/etalab-cadastre/"
ARCHIVE_BASE_URL = "https://files.data.gouv.fr/cadastre/etalab-cadastre/"   

# === Utilitaires ===
def confirm(prompt):
		"""Demander une confirmation à l'utilisateur"""
		while True:
				response = input(f"{prompt} (oui/non) : ").lower()
				if response in ['oui', 'o', 'yes', 'y']:
						return True
				elif response in ['non', 'n', 'no']:
						return False
				else:
						print("Veuillez répondre par 'oui' ou 'non'.")

def load_json(file_path):
    if os.path.exists(file_path):
        with open(file_path, 'r') as file:
            return json.load(file)
    return {}

def save_json(data, file_path):
    with open(file_path, 'w') as file:
        json.dump(data, file, indent=4)

def url_exists(url):
    """Vérifier si une URL existe"""
    try:
        response = requests.head(url)
        return response.status_code == 200
    except requests.RequestException:
        return False

# === Etape 1 - Gestion des dossiers ===
def initialize_directories(fromscratch=False):
		"""Initialiser les répertoires nécessaires pour le script"""
		if fromscratch:
				print("⚠️  Option '--fromscratch' activée. Cela va supprimer les dossiers existants.")
				
				# Double confirmation pour éviter les suppressions accidentelles
				if confirm("Êtes-vous sûr de vouloir tout supprimer ?") and confirm("Confirmez à nouveau, êtes-vous vraiment sûr ?"):
						print("Suppression des dossiers existants...")
						shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
						shutil.rmtree(LOG_DIR, ignore_errors=True)
						shutil.rmtree(ANOMALY_DIR, ignore_errors=True)
						shutil.rmtree(SUIVI_DIR, ignore_errors=True)
				else:
						print("Annulation de l'option '--fromscratch'.")
						return False
		# Créer les dossiers nécessaires
		os.makedirs(DOWNLOAD_DIR, exist_ok=True)
		os.makedirs(LOG_DIR, exist_ok=True)
		os.makedirs(ANOMALY_DIR, exist_ok=True)
		os.makedirs(SUIVI_DIR)
		print("Répertoires initialisés.")
		return True

# === Etape 2 - Srapping des dossiers ===
def get_last_modified(url):
    """Récupérer la date de dernière modification d'une URL"""
    try:
        response = requests.head(url)
        if 'Last-Modified' in response.headers:
            return response.headers['Last-Modified']
    except requests.RequestException as e:
        logging.error(f"Erreur lors de la récupération de la date pour {url}: {e}")
    return None

def get_versions_from_url(base_url):
    """Scraper les versions disponibles à partir d'une URL"""
    try:
        response = requests.get(base_url)
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')
        version_pattern = re.compile(r"\d{4}-\d{2}-\d{2}/")
        versions = [link['href'].strip('/') for link in soup.find_all('a', href=True) if version_pattern.match(link['href'])]
        return versions
    except Exception as e:
        logging.error(f"Erreur lors du scraping des versions depuis {base_url}: {e}")
    return []

def get_latest_version(base_url):
    """Récupérer la version correspondant à 'latest'"""
    latest_url = f"{base_url}latest/"
    latest_modified = get_last_modified(latest_url)
    
    if latest_modified:
        versions = get_versions_from_url(base_url)
        if versions:
            latest_version = versions[-1]  # La dernière version dans la liste
            return latest_version, latest_modified
    return None, None

# === Etape 3 - Gestion des changements et mise à jour du JSON ===
def update_versions(versions_data):
    """Mettre à jour le fichier versions.json avec les dernières informations"""
    new_versions = get_versions_from_url(NEW_BASE_URL)
    archived_versions = get_versions_from_url(ARCHIVE_BASE_URL)
    all_versions = sorted(set(new_versions + archived_versions))
    
    # Mise à jour des informations pour chaque version
    for version in all_versions:
        current_url = f"{NEW_BASE_URL}{version}/" if version in new_versions else f"{ARCHIVE_BASE_URL}{version}/"
        last_modified = get_last_modified(current_url)
        
        # Initialiser les données si le millésime est nouveau
        if version not in versions_data:
            versions_data[version] = {
                "history": [],
                "current": {}
            }
        
        # Comparer avec la dernière modification enregistrée
        current_info = versions_data[version]["current"]
        if current_info.get("last_modified") != last_modified:
            # Enregistrer l'historique
            versions_data[version]["history"].append({
                "status": "new" if version in new_versions else "archived",
                "url": current_url,
                "last_modified": last_modified,
                "source": "new" if version in new_versions else "archive",
                "archived": version in archived_versions,
                "checked_on": datetime.utcnow().isoformat()
            })
            # Mettre à jour la version actuelle
            versions_data[version]["current"] = {
                "status": "new" if version in new_versions else "archived",
                "url": current_url,
                "last_modified": last_modified,
                "source": "new" if version in new_versions else "archive",
                "archived": version in archived_versions
            }
    
    # Mettre à jour la version "latest"
    latest_version, latest_modified = get_latest_version(NEW_BASE_URL)
    if latest_version:
        versions_data["latest"] = {
            "alias": latest_version,
            "last_checked": datetime.utcnow().isoformat()
        }
    
    save_json(versions_data, VERSIONS_FILE)

def get_all_versions():
	"""Récupérer toutes les versions à jour du fichier versions.json"""
	return load_json(VERSIONS_FILE)
	
def update_changes_summary(changes_data, versions_data):
    """Mettre à jour le fichier changes_summary.json avec les changements détectés"""
    for version, data in versions_data.items():
        if "history" in data and len(data["history"]) > 1:
            previous_entry = data["history"][-2]
            current_entry = data["history"][-1]
            
            # Vérifier les changements de version
            if previous_entry["last_modified"] != current_entry["last_modified"]:
                change_record = {
                    "date": datetime.utcnow().isoformat(),
                    "type": "version_updated",
                    "version": version,
                    "new_last_modified": current_entry["last_modified"],
                    "previous_last_modified": previous_entry["last_modified"]
                }
                changes_data["changes"].append(change_record)
    
    save_json(changes_data, CHANGES_FILE)

# Etape 4 - télécharger les departements / communes et fichiers
def get_last_modified_and_size(url):
    """Récupérer la date de dernière modification et la taille d'un fichier à partir de l'URL"""
    try:
        response = requests.head(url)
        last_modified = response.headers.get('Last-Modified')
        size = int(response.headers.get('Content-Length', 0))
        return last_modified, size
    except requests.RequestException as e:
        logging.error(f"Erreur lors de la récupération des informations pour {url}: {e}")
        return None, None

def get_commune_files(department, commune, version):
    """Récupérer les fichiers pour une commune à partir de l'URL"""
    base_urls = [
        f"{NEW_BASE_URL}{version}/geojson/communes/{department}/{commune}/",
        f"{ARCHIVE_BASE_URL}{version}/geojson/communes/{department}/{commune}/"
    ]
    
    files = [
        "batiments", "communes", "feuilles", "lieux_dits",
        "parcelles", "prefixes_sections", "sections", "subdivisions_fiscales"
    ]
    
    commune_files = {}
    for file_type in files:
        for base_url in base_urls:
            file_url = f"{base_url}cadastre-{commune}-{file_type}.json.gz"
            last_modified, size = get_last_modified_and_size(file_url)
            if last_modified:
                commune_files[file_type] = {
                    "url": file_url,
                    "last_modified": last_modified,
                    "size": size
                }
                break
    return commune_files

def update_commune_json(department, commune, version, files_data):
    """Mettre à jour le JSON pour une commune avec un historique"""
    file_path = os.path.join(SUIVI_DIR, department, f"{commune}.json")
    data = load_json(file_path)

    if version not in data:
        data[version] = {
            "files": {},
            "last_checked": datetime.utcnow().isoformat()
        }

    for file_type, file_info in files_data.items():
        current_file = data[version]["files"].get(file_type, {})
        
        # Vérifier si le fichier a changé
        if (current_file.get("last_modified") != file_info["last_modified"] or
                current_file.get("size") != file_info["size"]):
            
            # Ajouter l'historique si un changement est détecté
            if "history" not in current_file:
                current_file["history"] = []
            
            # Enregistrer la version actuelle dans l'historique
            if current_file:
                current_file["history"].append({
                    "last_modified": current_file.get("last_modified"),
                    "size": current_file.get("size"),
                    "checked_on": data[version]["last_checked"]
                })

            # Mettre à jour les informations actuelles
            current_file["last_modified"] = file_info["last_modified"]
            current_file["size"] = file_info["size"]
            current_file["url"] = file_info["url"]

        data[version]["files"][file_type] = current_file

    # Mettre à jour la date de vérification
    data[version]["last_checked"] = datetime.utcnow().isoformat()

    save_json(data, file_path)
    logging.info(f"JSON mis à jour pour la commune {commune} dans le département {department}")

def get_departments(version):
    """Scraper la liste des départements pour une version donnée"""
    base_urls = [
        f"{NEW_BASE_URL}{version}/geojson/",
        f"{ARCHIVE_BASE_URL}{version}/geojson/"
    ]
    
    for base_url in base_urls:
        if not url_exists(base_url):
            continue
        try:
            response = requests.get(f"{base_url}communes/")
            response.raise_for_status()
            soup = BeautifulSoup(response.content, 'html.parser')
            departments = [link['href'].strip('/') for link in soup.find_all('a', href=True) if link['href'].strip('/').isdigit()]
            return departments
        except Exception as e:
            logging.error(f"Erreur lors de la récupération des départements pour {version}: {e}")
    return []

def get_communes(department, version):
    """Scraper la liste des communes pour un département donné"""
    base_urls = [
        f"{NEW_BASE_URL}{version}/geojson/communes/{department}/",
        f"{ARCHIVE_BASE_URL}{version}/geojson/communes/{department}/"
    ]
    
    for base_url in base_urls:
        if not url_exists(base_url):
            continue
        try:
            response = requests.get(base_url)
            response.raise_for_status()
            soup = BeautifulSoup(response.content, 'html.parser')
            communes = [link['href'].strip('/') for link in soup.find_all('a', href=True) if link['href'].strip('/').isdigit()]
            return communes
        except Exception as e:
            logging.error(f"Erreur lors de la récupération des communes pour le département {department}: {e}")
    return []
# === Main ===
def main():
		# Parser les arguments
		parser = argparse.ArgumentParser(description="Script de téléchargement du cadastre")
		parser.add_argument('--fromscratch', action='store_true', help="Recommencer le téléchargement en supprimant les dossiers existants")
		args = parser.parse_args()
		
		# Initialiser les dossiers avec l'option '--fromscratch'
		if not initialize_directories(fromscratch=args.fromscratch):
				print("Opération annulée.")
				return

		print("Lancement du script...")

		logging.info("Démarrage du script de mise à jour des versions")
		update_versions(versions_data)
		update_changes_summary(changes_data, versions_data)
		


		logging.info("Mise à jour terminée")

if __name__ == "__main__":
		main()
