import os
import requests
import datetime
import smtplib
import logging
from email.mime.text import MIMEText
from bs4 import BeautifulSoup
from apscheduler.schedulers.blocking import BlockingScheduler
import argparse

# Configuration des chemins et des URL
BASE_URL = "https://static.data.gouv.fr/resources/demandes-de-valeurs-foncieres/"
DATASET_URL = "https://www.data.gouv.fr/fr/datasets/demandes-de-valeurs-foncieres/"
DOWNLOAD_DIR = "valeurs_foncieres"
LOG_DIR = os.path.join(DOWNLOAD_DIR, "logs")
DOCUMENTATION_DIR = os.path.join(DOWNLOAD_DIR, "documentation")
EMAIL_ADDRESS = "donotreply@ms.tododev.fr"
EMAIL_PASSWORD = "eCJPHwBP4eTuIO81HhHL"
SMTP_SERVER = "smtp.ionos.fr"
SMTP_PORT = 587

# Configuration du logger
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
logging.basicConfig(filename=os.path.join(LOG_DIR, 'download_log.log'), level=logging.INFO)

def send_email(subject, body):
    msg = MIMEText(body)
    msg['Subject'] = subject
    msg['From'] = EMAIL_ADDRESS
    msg['To'] = EMAIL_ADDRESS

    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT) as server:
        server.starttls()
        server.login(EMAIL_ADDRESS, EMAIL_PASSWORD)
        server.sendmail(EMAIL_ADDRESS, EMAIL_ADDRESS, msg.as_string())

def get_latest_files():
    logging.info("Fetching latest files from dataset URL")
    response = requests.get(DATASET_URL)
    soup = BeautifulSoup(response.content, 'html.parser')
    files = soup.find_all('a', href=True)
    latest_files = []
    for file in files:
        if file['href'].startswith(BASE_URL):
            latest_files.append(file['href'])
    logging.info(f"Found {len(latest_files)} files")
    return latest_files

def download_file(url):
    logging.info(f"Downloading file from URL: {url}")
    response = requests.get(url, stream=True)
    if response.status_code == 200:
        filename = os.path.basename(url)
        # Extraire la date et le nom du fichier dans l'URL
        try:
            url_parts = url.split('/')
            date_str = url_parts[-2]
            file_name = url_parts[-1]
            year = file_name.split('-')[1][:4]  # Extraire l'année du fichier
        except IndexError:
            logging.error(f"Unable to extract date or filename from URL: {url}")
            return None

        # Si le fichier est un PDF, le placer dans le dossier documentation
        if filename.endswith('.pdf'):
            doc_path = os.path.join(DOCUMENTATION_DIR, filename)
            if not os.path.exists(DOCUMENTATION_DIR):
                os.makedirs(DOCUMENTATION_DIR)
            if not os.path.exists(doc_path):
                with open(doc_path, 'wb') as file:
                    for chunk in response.iter_content(chunk_size=8192):
                        file.write(chunk)
                logging.info(f"Downloaded: {url} to {doc_path}")
            else:
                logging.info(f"File already exists: {doc_path}")
            return doc_path

        # Créer le répertoire pour l'année si nécessaire
        year_dir = os.path.join(DOWNLOAD_DIR, year)
        if not os.path.exists(year_dir):
            os.makedirs(year_dir)

        # Nommer le fichier selon la date dans l'URL
        new_filename = f"{date_str}{os.path.splitext(filename)[1]}"
        filepath = os.path.join(year_dir, new_filename)

        # Télécharger le fichier s'il n'existe pas déjà
        if not os.path.exists(filepath):
            with open(filepath, 'wb') as file:
                for chunk in response.iter_content(chunk_size=8192):
                    file.write(chunk)
            logging.info(f"Downloaded: {url} to {filepath}")
        else:
            logging.info(f"File already exists: {filepath}")
        return filepath
    else:
        logging.error(f"Failed to download: {url}")
        return None

def main():
    try:
        logging.info("Starting download process")
        latest_files = get_latest_files()
        for file_url in latest_files:
            download_file(file_url)
        send_email("Download Script Success", "The download script executed successfully.")
    except Exception as e:
        logging.error(f"Error during download: {e}")
        send_email("Error in Download Script", str(e))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download latest files from data.gouv.fr")
    parser.add_argument('--force', action='store_true', help="Run the script once immediately")
    args = parser.parse_args()

    if args.force:
        main()
    else:
        scheduler = BlockingScheduler()
        scheduler.add_job(main, 'interval', weeks=1)
        scheduler.start()
