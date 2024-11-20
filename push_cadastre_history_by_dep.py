import os
import json
import gzip
import argparse
import psycopg2
import fiona
from psycopg2 import sql
from concurrent.futures import ThreadPoolExecutor, as_completed

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

# Connexion à PostgreSQL
def connect_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        print(f"Erreur lors de la connexion à la base de données : {e}")
        return None

def create_schema(conn, schema_name):
    """Créer un schéma pour chaque millésime"""
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema_name)))
            print(f"Schéma {schema_name} créé.")
    except Exception as e:
        print(f"Erreur lors de la création du schéma {schema_name} : {e}")

def create_table(conn, schema_name, department, file_type, columns):
    """Créer une table dans PostgreSQL avec des colonnes dynamiques"""
    table_name = f"{file_type}_{department}"
    columns_definition = ", ".join([f"{col} CHARACTER VARYING" for col in columns])
    
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql.SQL(f"""
                CREATE TABLE IF NOT EXISTS {schema_name}.{table_name} (
                    {columns_definition},
                    geom GEOMETRY(Geometry, 4326)
                )
            """))
            print(f"Table {table_name} créée dans le schéma {schema_name}.")
    except Exception as e:
        print(f"Erreur lors de la création de la table {table_name} : {e}")

def decompress_gz(file_path):
    """Décompresser un fichier .gz et retourner le chemin du fichier décompressé"""
    temp_file_path = file_path.replace(".gz", "")
    with gzip.open(file_path, 'rt', encoding='utf-8') as gz_file:
        with open(temp_file_path, 'w', encoding='utf-8') as json_file:
            json_file.write(gz_file.read())
    return temp_file_path

def get_columns_from_json(file_path):
    """Extraire toutes les colonnes présentes dans le fichier GeoJSON"""
    columns = set()
    with open(file_path, 'r') as f:
        data = json.load(f)
        if data.get('features'):
            for feature in data['features']:
                columns.update(feature['properties'].keys())
    return [key.lower() for key in columns]


def load_data_with_fiona(conn, schema_name, department, file_type, decompressed_file_path):
    """Charger les données dans PostgreSQL à partir d'un fichier GeoJSON décompressé"""

    table_name = f"{file_type}_{department}"

    try:
        # Charger le fichier avec Fiona
        with fiona.open(decompressed_file_path, 'r') as src:
            with conn.cursor() as cursor:
                # Récupérer les colonnes existantes dans la table
                cursor.execute(sql.SQL("""
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = %s AND table_name = %s
                """), (schema_name, table_name))
                table_columns = [row[0] for row in cursor.fetchall()]

                for feature in src:
                    columns = {k.lower(): v for k, v in feature['properties'].items()}  # Normaliser en minuscules
                    geom = feature['geometry']
                    
                    # Retenir uniquement les colonnes présentes dans la table
                    valid_columns = {k: v for k, v in columns.items() if k in table_columns}

                    # Vérifier si la géométrie existe
                    if geom is None:
                        print(f"Avertissement : Géométrie absente pour une entité dans {table_name}")
                        continue

                    # Convertir l'objet Fiona.Geometry en GeoJSON
                    geom_geojson = {
                        "type": geom["type"],
                        "coordinates": geom["coordinates"]
                    }


                    # Préparer les colonnes et les valeurs
                    columns_str = ', '.join(valid_columns.keys())
                    placeholders = ', '.join(['%s' for _ in valid_columns])
                    query = sql.SQL(f"""
                        INSERT INTO {schema_name}.{table_name} ({columns_str}, geom)
                        VALUES ({placeholders}, ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326))
                    """)

                    # Insertion des données
                    cursor.execute(query, list(valid_columns.values()) + [json.dumps(geom_geojson)])
        print(f"Les données ont été importées pour {table_name}")

    except Exception as e:
        print(f"Erreur lors de l'import des données pour {table_name}: {e}")

    finally:
        # Supprimer le fichier temporaire après le traitement
        os.remove(decompressed_file_path)

# def process_files():
#     conn = connect_db()
#     if not conn:
#         return

#     base_dir = "cadastre/data"
#     for millesime in os.listdir(base_dir):
#         print(f"Traitement du millésime : {millesime}")
#         schema_name = f"cadastre_{millesime.replace('-', '_')}"
#         create_schema(conn, schema_name)
        
#         millesime_path = os.path.join(base_dir, millesime)
#         if os.path.isdir(millesime_path):
#             for department in os.listdir(millesime_path):
#                 print(f"Traitement du département : {department}")
#                 department_path = os.path.join(millesime_path, department)
#                 if os.path.isdir(department_path):
#                     # Recupérer les fichiers .json.gz
#                     for file_name in os.listdir(department_path):
#                         if file_name.endswith('.json.gz'):
#                             # décompresser le fichier temporairement
#                             file_type = file_name.split('-')[-1].replace('.json.gz', '')
#                             decompressed_file_path = decompress_gz(os.path.join(department_path, file_name))
#                             columns = get_columns_from_json(decompressed_file_path)
#                             create_table(conn, schema_name, department, file_type, columns)
#                             load_data_with_fiona(conn, schema_name, department, file_type, decompressed_file_path)
#     conn.close()



# if __name__ == "__main__":
#     process_files()

def process_file(millesime, department, file_name, conn):
    """Traitement individuel d'un fichier"""
    schema_name = f"cadastre_{millesime.replace('-', '_')}"
    file_type = file_name.split('-')[-1].replace('.json.gz', '')
    decompressed_file_path = decompress_gz(os.path.join(DATA_DIR, millesime, department, file_name))
    columns = get_columns_from_json(decompressed_file_path)
    create_table(conn, schema_name, department, file_type, columns)
    load_data_with_fiona(conn, schema_name, department, file_type, decompressed_file_path)

def process_files_concurrently(max_workers=4):
    """Traitement des fichiers en parallèle"""
    conn = connect_db()
    if not conn:
        return

    base_dir = DATA_DIR
    tasks = []

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        for millesime in os.listdir(base_dir):
            print(f"Traitement du millésime : {millesime}")
            schema_name = f"cadastre_{millesime.replace('-', '_')}"
            create_schema(conn, schema_name)

            millesime_path = os.path.join(base_dir, millesime)
            if os.path.isdir(millesime_path):
                for department in os.listdir(millesime_path):
                    print(f"Traitement du département : {department}")
                    department_path = os.path.join(millesime_path, department)
                    if os.path.isdir(department_path):
                        for file_name in os.listdir(department_path):
                            if file_name.endswith('.json.gz'):
                                # Ajouter chaque fichier en tant que tâche
                                tasks.append(executor.submit(process_file, millesime, department, file_name, conn))

        # Afficher l'état des tâches au fur et à mesure
        for future in as_completed(tasks):
            try:
                future.result()
            except Exception as e:
                print(f"Erreur dans le traitement : {e}")

    conn.close()

if __name__ == "__main__":
    process_files_concurrently(max_workers=10)