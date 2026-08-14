import requests
from bs4 import BeautifulSoup
import re
import logging
from datetime import datetime

def get_folder_name_and_date(base_url):
    """Scraper les versions disponibles et leurs dates à partir d'une URL"""
    try:
        response = requests.get(base_url)
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
                # Extraire la date d'ajout après le lien
                date_match = re.search(r'\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}', line)
                if date_match:
                    # Conversion en datetime
                    raw_date = date_match.group()
                    # Convertir la date au format datetime
                    date_obj = datetime.strptime(raw_date, '%d-%b-%Y %H:%M')
                    # Formater la date en 'YYYY-MM-DD HH:MM'
                    formatted_date = date_obj.strftime('%Y-%m-%d %H:%M')
                    versions_dates.append((millesime, formatted_date, base_url))
        
        return versions_dates

    except Exception as e:
        logging.error(f"Erreur lors du scraping des versions depuis {base_url}: {e}")
    return []

# Exemple d'utilisation
if __name__ == "__main__":
    base_url = "https://cadastre.data.gouv.fr/data/etalab-cadastre/"
    versions = get_millesime_versions_from_url(base_url)
    
    # Afficher le tableau obtenu
    for millesime, date_ajout, base_url in versions:
        print(f"Millésime : {millesime} | Date d'ajout : {date_ajout} | URL : {base_url}")
