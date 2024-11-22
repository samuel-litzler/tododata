import os
import json
import gzip
import argparse
import psycopg2
import fiona
from psycopg2 import sql

# Configuration de la base de données PostgreSQL
DB_CONFIG = {
    "dbname": "historique_cadastre",
    "user": "postgres",
    "password": "postgres",
    "host": "localhost",
    "port": "5432"
}

# Chemins des répertoires
DATA_DIR = "data"
LOG_DIR = "cadastre/logs"
os.makedirs(LOG_DIR, exist_ok=True)

# Connexion à PostgreSQL
def connect_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"Erreur lors de la connexion à la base de données : {e}")
        return None

def create_schema(conn, millesime):
    """Créer un schéma pour chaque millésime"""
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(millesime)))
            print(f"Schéma {millesime} créé.")
    except Exception as e:
        print(f"Erreur lors de la création du schéma {millesime} : {e}")

def create_table(conn, millesime, department, file_type, columns):
    """Créer une table pour chaque type de fichier avec des colonnes dynamiques"""
    table_name = f"{department}_{file_type}"
    try:
        columns_definitions = ", ".join([f"{col} TEXT" for col in columns])
        query = f"""
            CREATE TABLE IF NOT EXISTS {millesime}.{table_name} (
                id SERIAL PRIMARY KEY,
                insee_code VARCHAR(10),
                {columns_definitions},
                geom GEOMETRY(Geometry, 4326)
            );
        """
        with conn.cursor() as cursor:
            cursor.execute(query)
            print(f"Table {table_name} créée dans le schéma {millesime}.")
    except Exception as e:
        print(f"Erreur lors de la création de la table {table_name} : {e}")

def create_index(conn, millesime, table_name):
    """Créer un index spatial sur le champ geom"""
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql.SQL("""
                CREATE INDEX IF NOT EXISTS {}_geom_idx ON {}.{} USING GIST (geom)
            """).format(
                sql.Identifier(f"{table_name}_geom_idx"),
                sql.Identifier(millesime),
                sql.Identifier(table_name)
            ))
            print(f"Index créé pour la table {table_name}.")
    except Exception as e:
        print(f"Erreur lors de la création de l'index pour {table_name} : {e}")

def load_data_with_fiona(conn, millesime, department, file_name):
    """Charger les données à partir d'un fichier .json.gz en utilisant Fiona"""
    table_name = f"{department}_{file_name.split('-')[-1].replace('.json.gz', '')}"
    file_path = os.path.join(DATA_DIR, millesime, department, file_name)
    
    with fiona.open(f"zip://{file_path}", 'r') as src:
        # Extraire les colonnes à partir des propriétés du premier enregistrement
        first_feature = next(iter(src), None)
        if not first_feature:
            print(f"Fichier vide : {file_name}")
            return
        
        columns = list(first_feature['properties'].keys())
        create_table(conn, millesime, department, table_name, columns)
        
        # Insérer les données
        with conn.cursor() as cursor:
            for feature in src:
                properties = feature['properties']
                geom = feature['geometry']
                
                # Construction de la requête d'insertion
                columns_str = ', '.join(properties.keys())
                values_str = ', '.join(['%s'] * len(properties))
                insert_query = f"""
                    INSERT INTO {millesime}.{table_name} (insee_code, {columns_str}, geom)
                    VALUES (%s, {values_str}, ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))
                """
                
                # Préparer les valeurs à insérer
                insee_code = properties.get('code_insee', None)
                values = list(properties.values())
                values.append(json.dumps(geom))
                
                try:
                    cursor.execute(insert_query, [insee_code] + values)
                except Exception as e:
                    print(f"Erreur lors de l'insertion dans {table_name} : {e}")

def process_files(start=None, end=None):
    conn = connect_db()
    if not conn:
        return

    millesimes = sorted(os.listdir(DATA_DIR))
    
    # Filtrer les millésimes si --start et --end sont fournis
    if start:
        millesimes = [m for m in millesimes if m >= start]
    if end:
        millesimes = [m for m in millesimes if m <= end]

    for millesime in millesimes:
        print(f"Traitement du millésime : {millesime}")
        create_schema(conn, millesime)
        
        departments = os.listdir(os.path.join(DATA_DIR, millesime))
        for department in departments:
            files = os.listdir(os.path.join(DATA_DIR, millesime, department))
            for file_name in files:
                if file_name.endswith('.json.gz'):
                    print(f"Chargement du fichier {file_name} pour le département {department}")
                    load_data_with_fiona(conn, millesime, department, file_name)
                    table_name = f"{department}_{file_name.split('-')[-1].replace('.json.gz', '')}"
                    create_index(conn, millesime, table_name)
    
    conn.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Importer les données du cadastre en base PostgreSQL")
    parser.add_argument('--start', type=str, help="Millésime de début")
    parser.add_argument('--end', type=str, help="Millésime de fin")
    args = parser.parse_args()

    process_files(args.start, args.end)
