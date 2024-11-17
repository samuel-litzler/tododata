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

# === Etape 1 - Initialisation et configuration
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
		os.makedirs(SUIVI_DIR, exist_ok=True)
		return True

# === Etape 2 - Téléchargement des millesimes
def get_millesime_versions_from_url(base_url):
    """Scraper les versions disponibles à partir d'une URL"""
    try:
        response = requests.get(base_url)
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')
        version_pattern = re.compile(r"\d{4}-\d{2}-\d{2}/")
        # structure html type : 
        # <a href="../">../</a> (retour au dossier parent, on s'en fiche)
        # <a href="2021-07-01/">2021-07-01/</a> (debut d'une ligne : lien vers une version)
        # 12-Nov-2024 16:02       - (fin d'une ligne : date de dernière modification, c'est un text mais sans balise)

        # // Il faut retourner un tableau avec les versions et les dates de dernière modification
        versions = [link['href'].strip('/') for link in soup.find_all('a', href=True) if version_pattern.match(link['href'])]
        # Les dates sans après le <a></a> de la version et avant le <a></a> suivant
        # // On récupère les dates de dernière modification
        dates = [date.text for date in soup.find_all('a', href=True) if not version_pattern.match(date.text)]
        # // On retourne un tableau de tuples (version, date)
        return list(zip(versions, dates))
       

        return versions
    except Exception as e:
        logging.error(f"Erreur lors du scraping des versions depuis {base_url}: {e}")
    return []

def get_latest_millesime(base_url):
    """Récupérer la version correspondant à 'latest'"""
    latest_url = f"{base_url}latest/"
    latest_modified = get_last_modified(latest_url)
    
    if latest_modified:
        versions = get_versions_from_url(base_url)
        if versions:
            latest_version = versions[-1]  # La dernière version dans la liste
            return latest_version, latest_modified
    return None, None

def update_millesimes_versions():
    """Mettre à jour le fichier versions.json avec les dernières informations
        
        Fonction principale pour mettre à jour les versions et les historiques des millésimes.
    """
    logging.info("Mise à jour des versions")
    new_versions = get_millesime_versions_from_url(NEW_BASE_URL)
    archived_versions = get_millesime_versions_from_url(ARCHIVE_BASE_URL)
    all_versions = sorted(set(new_versions + archived_versions))
    logging.info(f"{len(all_versions)} versions récupérées")
    for version in all_versions:
        current_url = f"{NEW_BASE_URL}{version}/" if version in new_versions else f"{ARCHIVE_BASE_URL}{version}/"
        last_modified = get_last_modified(current_url)
        logging.info(f"Version {version} : {last_modified}")

    # Mise à jour des informations pour chaque version
    # for version in all_versions:
    #     current_url = f"{NEW_BASE_URL}{version}/" if version in new_versions else f"{ARCHIVE_BASE_URL}{version}/"
    #     last_modified = get_last_modified(current_url)
        
    #     # Initialiser les données si le millésime est nouveau
    #     if version not in versions_data:
    #         versions_data[version] = {
    #             "history": [],
    #             "current": {}
    #         }
        
    #     # Comparer avec la dernière modification enregistrée
    #     current_info = versions_data[version]["current"]
    #     if current_info.get("last_modified") != last_modified:
    #         # Enregistrer l'historique
    #         versions_data[version]["history"].append({
    #             "status": "new" if version in new_versions else "archived",
    #             "url": current_url,
    #             "last_modified": last_modified,
    #             "source": "new" if version in new_versions else "archive",
    #             "archived": version in archived_versions,
    #             "checked_on": datetime.utcnow().isoformat()
    #         })
    #         # Mettre à jour la version actuelle
    #         versions_data[version]["current"] = {
    #             "status": "new" if version in new_versions else "archived",
    #             "url": current_url,
    #             "last_modified": last_modified,
    #             "source": "new" if version in new_versions else "archive",
    #             "archived": version in archived_versions
    #         }
    
    # # Mettre à jour la version "latest"
    # latest_version, latest_modified = get_latest_version(NEW_BASE_URL)
    # if latest_version:
    #     versions_data["latest"] = {
    #         "alias": latest_version,
    #         "last_checked": datetime.utcnow().isoformat()
    #     }
    
    # save_json(versions_data, VERSIONS_FILE)

def get_last_modified(url):
    """Récupérer la date de dernière modification d'une URL"""
    try:
        response = requests.head(url)
        if 'Last-Modified' in response.headers:
            return response.headers['Last-Modified']
    except requests.RequestException as e:
        logging.error(f"Erreur lors de la récupération de la date pour {url}: {e}")
    return None

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
    
    logging.info("Démarrage du script de mise à jour des versions")
    update_millesimes_versions()

    logging.info("Mise à jour terminée")

if __name__ == "__main__":
		main()
