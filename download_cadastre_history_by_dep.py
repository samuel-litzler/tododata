import requests
from bs4 import BeautifulSoup
import re
import logging
import requests
import time
from datetime import datetime
import json
import os

DOWNLOAD_DIR = "cadastre"
LOG_DIR = os.path.join(DOWNLOAD_DIR, "logs")
ANOMALY_DIR = os.path.join(LOG_DIR, "anomalies")
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(ANOMALY_DIR, exist_ok=True)

requests_counter = {"verif_url": 0, "download": 0, "get_links": 0}


# === Téléchargement des versions ===

def get_folder_name_and_date(base_url):
    """Scraper les versions disponibles et leurs dates à partir d'une URL"""
    try:
        response = requests.get(base_url)
        update_counter("get_links")
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')

        versions_dates = []
        # Extraire toutes les lignes du HTML
        lines = soup.prettify().splitlines()
        version_pattern = re.compile(r'<a href="(\d{4}-\d{2}-\d{2})/">')
        
        for line in lines:
            # Recherche du millésime
            version_match = version_pattern.search(line)
            if version_match:
                millesime = version_match.group(1)
                date_match = re.search(r'\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}', line)
                if date_match:
                    # Conversion en datetime
                    raw_date = date_match.group()
                    # Convertir la date au format datetime
                    date_obj = datetime.strptime(raw_date, '%d-%b-%Y %H:%M')
                    # Formater la date en 'YYYY-MM-DD HH:MM'
                    formatted_date = date_obj.strftime('%Y-%m-%d %H:%M')
                    versions_dates.append((millesime, formatted_date, base_url))
        
        versions_dates = [v for v in versions_dates if v[0] != "latest"]
        return versions_dates

    except Exception as e:
        logging.error(f"Erreur lors du scraping des versions depuis {base_url}: {e}")
    return []

def get_file_name_date_size(base_url):
    """Scraper les fichiers disponibles et leurs dates à partir d'une URL"""
    try:
        response = requests.get(base_url)
        update_counter("get_links")
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')

        files_dates = []
        # Extraire toutes les lignes du HTML
        lines = soup.prettify().splitlines()
        print(lines)
        file_pattern = re.compile(r'<a href="(.+?)">(.+?)</a>\s+(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2})\s+(\d+[KMG]|\d+)')
        for line in lines:
            # Recherche du fichier
            file_match = file_pattern.search(line)
            print(file_match)
            if file_match:
                file_name = file_match.group(1)
                date = file_match.group(3)
                size = file_match.group(4)
                files_dates.append((file_name, date, size))
        return files_dates
    except Exception as e:
        logging.error(f"Erreur lors du scraping des fichiers depuis {base_url}: {e}")
    return []


def update_millesime_history(versions):
    """Mettre à jour l'historique des millésimes"""
    # Etape 1 : récupérer le fichier JSON, s'il existe déjà
    try:
        with open(DOWNLOAD_DIR + "/millesime_history.json", "r") as file:
            millesime_history = json.load(file)
    except FileNotFoundError:
        millesime_history = {"versions": {}, "latest": {}}  # Créer un nouveau dictionnaire
    except json.JSONDecodeError:
        logging.error("Erreur lors de la lecture du fichier JSON")
        return

    # Etape 2 : mettre à jour l'historique des millésimes
    for millesime, date_ajout, base_url in versions:
        if millesime not in millesime_history["versions"]:
            millesime_history["versions"][millesime] = {"history": [], "current": {}}
        millesime_history["versions"][millesime]["history"].append({"url": base_url, "last_modified": date_ajout, "checked_on": datetime.now().isoformat()})
        millesime_history["versions"][millesime]["current"] = {"url": base_url, "last_modified": date_ajout}

    # Etape 3 : Voir s'il y a un changment du latest, si oui alors il faut le notifier
    latest_millesime = sorted(millesime_history["versions"].keys())[-1]
    if latest_millesime != millesime_history["latest"].get("alias"):
        millesime_history["latest"] = {"alias": latest_millesime, "last_checked": datetime.now().isoformat()}
        logging.info(f"Nouveau millésime détecté : {latest_millesime}")
        # TODO envoyer un email pour notifier le changement

    # Etape 4 : Sauvegarder le fichier JSON
    with open(DOWNLOAD_DIR + "/millesime_history.json", "w") as file:
        json.dump(millesime_history, file, indent=2)

    # Etape 5 : Retourner les urls des current versions en tableau [{millesime: url}, ...]
    version_and_url = [(m, millesime_history["versions"][m]["current"]["url"]) for m in millesime_history["versions"]]
    version_and_url = sorted(version_and_url, key=lambda x: x[0])
    return version_and_url


# === Utils ===
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

def check_url(url, name, type):
    """Vérifier en fonction d'un type et d'un nom si un lien existe dans le HTML"""
    
    # Verifier si l'url est valide / requetable
    try:
        response = requests.get(url)
        update_counter("verif_url")
        response.raise_for_status()
    except Exception as e:
        logging.error(f"Erreur lors de la vérification de l'URL {url}: {e}")
        return False

    # type folder -> va chercher si un lien contient le name dans l'html, en gros ça veut dire que c'est un dossier
    if type == "folder":
        try:
            response = requests.get(url)
            update_counter("verif_url")
            response.raise_for_status()
            soup = BeautifulSoup(response.content, 'html.parser')
            return any(name in link['href'] for link in soup.find_all('a', href=True))
        except Exception as e:
            logging.error(f"Erreur lors de la vérification de l'URL {url}, type {type}: , name {name}: {e}")
            return False
    else:
        logging.error(f"Aucun type de vérification n'est défini pour {type}")
        return False

def get_all_links(url, without_final_slash=True):
    """Récupérer tous les liens d'une page HTML"""
    try:
        response = requests.get(url)
        update_counter("get_links")
        response.raise_for_status()
        soup = BeautifulSoup(response.content, 'html.parser')
        links = [link['href'].strip('/') for link in soup.find_all('a', href=True)]
        if without_final_slash:
            links = [link.strip('/') for link in links]
        return links
    except Exception as e:
        logging.error(f"Erreur lors de la récupération des liens de la page {url}: {e}")
        return []

def update_counter(type):
    requests_counter[type] += 1
    json.dump(requests_counter, open(os.path.join(DOWNLOAD_DIR, "requests_counter.json"), "w"))


def download_file(download_url, file_path, max_retries=3):
    """
    Télécharge un fichier avec gestion des erreurs et des tentatives multiples.
    
    Args:
        version_url (str): URL de la version.
        department (str): Code du département.
        commune (str): Code INSEE de la commune.
        file_name (str): Nom du fichier à télécharger.
        file_path (str): Chemin où sauvegarder le fichier.
        max_retries (int): Nombre maximum de tentatives en cas d'échec.
    
    Returns:
        bool: True si le téléchargement réussit, sinon False.
    """
    attempt = 0
    while attempt < max_retries:
        try:
            logging.info(f"Téléchargement du fichier : {download_url} (tentative {attempt + 1}/{max_retries})")
            response = requests.get(download_url, stream=True, timeout=10)
            update_counter("download")
            response.raise_for_status()  # Lève une exception pour les codes d'erreur HTTP

            # Écriture du contenu dans le fichier
            with open(file_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    f.write(chunk)
            
            logging.info(f"Fichier téléchargé avec succès : {file_path}")
            return True

        except requests.exceptions.RequestException as e:
            attempt += 1
            logging.warning(f"Erreur lors du téléchargement ({attempt}/{max_retries}): {e}")
            time.sleep(5)  # Attendre 5 secondes avant de réessayer

    # Si toutes les tentatives échouent
    logging.error(f"Échec du téléchargement après {max_retries} tentatives : {download_url}")
    return False


# Exemple d'utilisation
if __name__ == "__main__":
    base_url = "https://cadastre.data.gouv.fr/data/etalab-cadastre/"
    versions = get_folder_name_and_date(base_url)
    json.dump(requests_counter, open(os.path.join(DOWNLOAD_DIR, "requests_counter.json"), "w"))

    base_url_archive = "https://files.data.gouv.fr/cadastre/etalab-cadastre/"
    versions_archive = get_folder_name_and_date(base_url_archive)
    global_logger = setup_logger("global")
    # Il est possible que des millésimes soient présents dans les urls, il faut prendre en priorité le millesime d'archive
    # Si une version existe dans les deux, il faut prendre celle de l'archive
    # Vérifier les versions et faire un warning si une version est présente dans les deux
    for millesime, date_ajout, base_url in versions:
        if any(millesime == millesime_archive for millesime_archive, _, _ in versions_archive):
            global_logger.warning(f"Le millésime {millesime} est présent dans les deux dossiers")
            # supprimer la version de la liste des versions
            versions = [(m, d, u) for m, d, u in versions if m != millesime]

    # Fusionner les deux listes
    versions += versions_archive
    current_versions_urls = update_millesime_history(versions)

    # A cette étape on a les urls des versions actuelles, on va doit aller vérifier que le dossier geojson existe pour chaque version
    # et récupérer les communes de chaque département
    for millesime, version_url in current_versions_urls:
        logger = setup_logger(millesime)
        anomaly_logger = setup_logger(f"anomalies_{millesime}")

        global_logger.info(f"Traitement de la version {millesime}")
        # scrap l'url et vérifier qu'un dossier "geojson" existe en uttilisant la fonction check_url
        version_url = f"{version_url}{millesime}/"
        has_geojson_folder = check_url(f"{version_url}", "geojson", "folder")
        if not has_geojson_folder:
            logger.error(f"Le dossier geojson n'existe pas pour {version_url}")
            continue
        # si oui, récupérer les départements
        has_communes_folder = check_url(f"{version_url}geojson/", "communes", "folder")
        if not has_communes_folder:
            logger.error(f"Le dossier communes n'existe pas pour {version_url}")
            continue
        # Le dossier communes à une liste de départements, on va les récupérer
        departments = get_all_links(f"{version_url}geojson/departements/")
        departments = [d for d in departments if d != ".."]
        if not departments:
            logger.error(f"Aucun département trouvé pour {version_url}")
            continue

        
        # pour chaque département, récupérer les communes
        for department in departments:
            global_logger.info(f"===== Traitement du département {department} =====")

            # === Téléchargement au niveau du département ===
            department_files_online = get_file_name_date_size(f"{version_url}geojson/departements/{department}/")
            if not department_files_online:
                logger.error(f"Aucun fichier trouvé pour le département {department} de la version {millesime}")
                anomaly_logger.error(f"Aucun fichier trouvé pour le département {department} de la version {millesime}")
                continue

            # Chemins pour les dossiers de suivi et de téléchargement
            path = f"cadastre/suivi_fichiers/{millesime}/{department}/"
            path_dataset = f"cadastre/data/{millesime}/{department}/"
            os.makedirs(path, exist_ok=True)
            os.makedirs(path_dataset, exist_ok=True)

            # Chemin du fichier d'historique pour le département
            department_history_file_path = os.path.join(path, f"{department}.json")
            default_json_structure = {"files": {}, "last_checked": datetime.now().isoformat()}
            if not os.path.exists(department_history_file_path):
                with open(department_history_file_path, 'w') as f:
                    json.dump({millesime: default_json_structure}, f)

            with open(department_history_file_path, 'r') as f:
                department_json_history = json.load(f)

            if millesime not in department_json_history:
                department_json_history[millesime] = default_json_structure

            # Parcourir les fichiers du département
            for file_name, date, size in department_files_online:
                logger.info(f"=== Traitement du fichier {file_name} pour le département {department}")

                # Vérification des modifications du fichier
                if file_name not in department_json_history[millesime]["files"]:
                    # Initialisation si le fichier est nouveau
                    department_json_history[millesime]["files"][file_name] = {
                        "current": {"last_modified": date, "size": size},
                        "history": []
                    }
                else:
                    last_history = department_json_history[millesime]["files"][file_name]["history"][-1] if department_json_history[millesime]["files"][file_name]["history"] else {}

                    # Comparer la date et la taille pour détecter des changements
                    if last_history.get("last_modified") != date or last_history.get("size") != size:
                        # Log des changements détectés
                        if last_history.get("last_modified") != date:
                            anomaly_logger.warning(f"Le fichier {file_name} a changé de date pour le département {department} ({last_history.get('last_modified')} -> {date})")
                        if last_history.get("size") != size:
                            anomaly_logger.warning(f"Le fichier {file_name} a changé de taille pour le département {department} ({last_history.get('size')} -> {size})")

                        # Ajouter à l'historique
                        department_json_history[millesime]["files"][file_name]["history"].append({
                            "last_modified": date,
                            "size": size,
                            "checked_on": datetime.now().isoformat()
                        })
                
                # Mise à jour des informations actuelles
                department_json_history[millesime]["files"][file_name]["current"] = {
                    "last_modified": date,
                    "size": size
                }

                # Chemin pour stocker le fichier téléchargé
                file_path = os.path.join(path_dataset, file_name)

                # Télécharger le fichier, avec gestion des erreurs et des tentatives
                download_url = f"{version_url}geojson/departements/{department}/{file_name}"
                result = download_file(download_url, file_path)
                if not result:
                    anomaly_logger.error(f"Le fichier {file_name} n'a pas pu être téléchargé pour le département {department} de la version {millesime}")
                    continue

                logger.info(f"Le fichier {file_name} a été téléchargé pour le département {department} de la version {millesime}")

            # Sauvegarder l'historique mis à jour pour le département
            with open(department_history_file_path, 'w') as f:
                json.dump(department_json_history, f)
            logger.info(f"L'historique du département {department} a été mis à jour pour la version {millesime}")
    # Log des requêtes

    # TODO faire des logs dans un fichier suivi fichiers pour nombre fichiers par communes, nombre communes par dep + liste, nombre dep par version + liste
    # anoncer la last version pour que l'on puisse la traiter pour la mise à en db dans le futur