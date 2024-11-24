import psycopg2
from psycopg2 import sql
import logging

# Configuration de la base de donnees PostgreSQL
DB_CONFIG = {
    "dbname": "historique_cadastre",
    "user": "postgres",
    "password": "postgres",
    "host": "192.168.1.30",
    "port": "5432"
}
LOG_FILE = "cadastre/logs/create_commune_unique_by_dep.log"
# Configuration du logger
logging.basicConfig(
    level=logging.INFO,
    filename=LOG_FILE,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

def connect_db():
    """Connexion à la base de donnees PostgreSQL"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        return conn
    except Exception as e:
        logging.error(f"Erreur de connexion à la base de donnees : {e}")
        return None

def create_tables(conn):
    queries = [
        """
        CREATE SCHEMA IF NOT EXISTS reference;
        """,
        """
        CREATE SCHEMA IF NOT EXISTS historique;
        """,
        """
        CREATE SCHEMA IF NOT EXISTS stats;
        """,
        """
        CREATE TABLE IF NOT EXISTS reference.communes_unique (
            code_commune VARCHAR(5) PRIMARY KEY,
            code_departement VARCHAR(3) NOT NULL,
            nom_commune VARCHAR(100) NOT NULL,
            created TIMESTAMP,
            updated TIMESTAMP,
            status VARCHAR(255) DEFAULT 'active',
            fusioned_to VARCHAR(5),
            geom GEOMETRY(Geometry, 4326)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS historique.communes_changes (
            change_id SERIAL PRIMARY KEY,
            code_commune VARCHAR(5) NOT NULL,
            millesime VARCHAR(20) NOT NULL,
            change_type VARCHAR(255) NOT NULL,
            old_value TEXT,
            new_value TEXT,
            created TIMESTAMP,
            updated TIMESTAMP,
            diff_area_from_previous FLOAT,
            old_geom GEOMETRY(Geometry, 4326),
            new_geom GEOMETRY(Geometry, 4326)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS stats.stats_communes (
            millesime VARCHAR(20),
            code_departement VARCHAR(3),
            nb_communes INTEGER NOT NULL,
            PRIMARY KEY (millesime, code_departement)
        );
        """
    ]
    with conn.cursor() as cursor:
        for query in queries:
            cursor.execute(query)
    logging.info("Tables communes_unique, communes_changes et stats_communes creees ou dejà existantes.")


def process_communes_by_dep(conn, departement_table_name, millesime, previous_millesime):
    """Gerer la creation d'une table de communes uniques en comparant les millesimes successifs."""
    code_departement = departement_table_name.split("_")[-1]
    if previous_millesime is not None:
        logging.info(f"           Comparaison des communes pour le departement {code_departement} entre les millesimes {previous_millesime} et {millesime}.")

        # On recupere les communes actives de commune unique, cela correspond aux communes actives du millesime precedent
        get_actual_active_communes_in_dep = f"""
            SELECT code_commune, nom_commune, updated
            FROM reference.communes_unique
            WHERE code_departement = '{code_departement}' AND status = 'active'
            ORDER BY code_commune ASC;
        """
        with conn.cursor() as cursor:
            cursor.execute(get_actual_active_communes_in_dep)
            actives_commune_in_last_millesime = {row[0]: {"nom_commune": row[1], "updated": row[2]} for row in cursor.fetchall()}
        
        # normalement il existe des donnees mais on verifie quand même
        if not actives_commune_in_last_millesime:
            logging.error(f"           Aucune commune active trouvee pour le departement {departement_table_name} dans le millesime {previous_millesime}, ne devrait pas arriver")
            return
        
        # On recupere les communes actives du millesime actuel
        get_actual_active_communes_in_dep = f"""
            SELECT id, COALESCE(nom, 'Nom manquant'), updated::timestamp
            FROM cadastre_{millesime}.{departement_table_name};
        """
        with conn.cursor() as cursor:
            cursor.execute(get_actual_active_communes_in_dep)
            actives_commune_in_current_millesime = {row[0]: {"nom_commune": row[1], "updated": row[2]} for row in cursor.fetchall()}
        
        # TRAITEMENT VERIFICATION COMMUNES PAR COMMUNES
        for code_commune, pre_values in actives_commune_in_current_millesime.items():
            logging.info(f"             == com {code_commune} dep {code_departement} mil {millesime}")
            # Liste des actions a faire pour la commune :
            # - NEW : creation de la commune
            # - UPDATE_NAME : mise a jour du nom de la commune
            # - UPDATE_DATE : mise a jour de la date de mise a jour de la commune
            # - UPDATE_GEOM : mise a jour de la geometrie de la commune
            # - NO_CHANGE_GEOM : aucune modification de la geometrie de la commune

            # Verifier si la commune existe dans le millesime precedent
            if code_commune in actives_commune_in_last_millesime:
                # La commune existe dans le millesime precedent, verification du nom
                pre_values = actives_commune_in_last_millesime[code_commune]
                post_values = actives_commune_in_current_millesime[code_commune]
                if pre_values["nom_commune"] != post_values["nom_commune"]:
                    post_values["nom_commune"] = post_values["nom_commune"].replace("'", "''")
                    pre_values["nom_commune"] = pre_values["nom_commune"].replace("'", "''")
                    # Mettre a jour le nouveau nom de la commune, cas : UPDATE_NAME
                    update_name_query = f"""
                        UPDATE reference.communes_unique
                        SET nom_commune = '{post_values["nom_commune"]}'
                        WHERE code_commune = '{code_commune}';
                    """
                    save_change_query = f"""
                        INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                        VALUES ('{code_commune}', '{millesime}', 'name_update', '{pre_values["nom_commune"]}', '{post_values["nom_commune"]}');
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(update_name_query)
                        cursor.execute(save_change_query)
                        logging.info(f"             nom modifie : {pre_values['nom_commune']} -> {post_values['nom_commune']}")
                else:
                    logging.info(f"             nom no modif")
                if pre_values["updated"] != post_values["updated"]:
                    # Mettre a jour la date de mise a jour de la commune, cas : UPDATE_DATE
                    if post_values["updated"] is not None:
                        update_date_query = f"""
                            UPDATE reference.communes_unique
                            SET updated = '{post_values["updated"]}'
                            WHERE code_commune = '{code_commune}';
                        """
                        save_change_query = f"""
                            INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                            VALUES ('{code_commune}', '{millesime}', 'date_update', '{pre_values["updated"]}', '{post_values["updated"]}');
                        """
                        with conn.cursor() as cursor:
                            cursor.execute(update_date_query)
                            cursor.execute(save_change_query)
                            logging.info(f"             date modifiee : {pre_values['updated']} -> {post_values['updated']}")
                    else:
                        logging.warning(f"             La date de mise a jour de la commune est nulle, ne devrait pas arriver.")
                else:
                    logging.info(f"             date no modif")
                # Faire une requête pour comparer les geometries et retourner les m2 de difference
                #  - verifier si la geometrie existe dans le millesime precedent
                is_geom_exists_query = f"""
                    SELECT 1
                    FROM historique.communes_changes
                    WHERE code_commune = '{code_commune}' AND millesime = '{previous_millesime}' AND (change_type = 'created' OR change_type = 'geom_update') ORDER BY created DESC LIMIT 1;
                """
                with conn.cursor() as cursor:
                    cursor.execute(is_geom_exists_query)
                    geom_exists = cursor.fetchone()

                if geom_exists:
                    #  comparer les geometries et retourner les m2 de difference (attention geometrie en 4326, donc pour avoir des m2 il faut convertir en 2154)
                    compare_geom_query = f"""
                        SELECT ST_Area(ST_Transform(ST_Difference(
                            (SELECT ST_Transform(new_geom, 2154) FROM historique.communes_changes WHERE code_commune = '{code_commune}' AND millesime = '{previous_millesime}' AND (change_type = 'created' OR change_type = 'geom_update') ORDER BY created DESC LIMIT 1),
                            (SELECT ST_Transform(ST_MakeValid(geom), 2154) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                        ), 2154)) AS diff_area;
                    """
                    with conn.cursor() as cursor:
                        try:
                            cursor.execute(compare_geom_query)
                            diff_area = cursor.fetchone()[0]
                        except Exception as e:
                            diff_area = -1
                            logging.error(f"             Probleme pour valider les geometries pour com {code_commune} dep {code_departement} mil {millesime} : {e}")
                        if diff_area > 0:
                            # Cas : UPDATE_GEOM
                            # Mettre a jour la geometrie de la commune
                            update_geom_query = f"""
                                UPDATE reference.communes_unique
                                SET geom = (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                WHERE code_commune = '{code_commune}';
                            """
                            # normalement on aura qu'un retour car c'est soit une creation soit une mise a jour dans le precedent millesime
                            save_change_query = f"""
                                INSERT INTO historique.communes_changes (code_commune, millesime, change_type, diff_area_from_previous, old_geom, new_geom)
                                VALUES ('{code_commune}', '{millesime}', 'geom_update', {diff_area}, 
                                    (SELECT new_geom FROM historique.communes_changes WHERE code_commune = '{code_commune}' AND millesime = '{previous_millesime}' AND (change_type = 'geom_update' OR change_type = 'created') ORDER BY created DESC LIMIT 1),
                                    (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                );
                            """
                            with conn.cursor() as cursor:
                                cursor.execute(update_geom_query)
                                cursor.execute(save_change_query)
                            logging.info(f"             diff surf : {diff_area}")
                        elif diff_area == 0:
                            # Aucune modification de la geometrie de la commune, pas besoin de mettre a jour, cas : NO_CHANGE_GEOM
                            logging.info(f"             geom no modif")
                else:
                    logging.warning(f"             Recuperation de la geometrie dans les communes uniques car elle n'a subit aucun changement depuis plus d'un millesime")
                    # Attention ! Si la commune n'a eu aucune modification de geometrie dans le millesime precedent, la geometrie n'existera pas
                    # Mais ça ne veut pas dire que la commune n'existe pas, on peut donc recuperer de communes_unique
                    get_geom_query = f"""
                        SELECT 1
                        FROM reference.communes_unique
                        WHERE code_commune = '{code_commune}';
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(get_geom_query)
                        geom = cursor.fetchone()
                    if geom:
                        # On doit donc comparer la geometrie de la commune avec la geometrie de communes_unique sans faire attention au precedent millesime
                        compare_geom_query = f"""
                            SELECT ST_Area(ST_Transform(ST_Difference(
                                (SELECT ST_Transform(geom, 2154) FROM reference.communes_unique WHERE code_commune = '{code_commune}'),
                                (SELECT ST_Transform(ST_MakeValid(geom), 2154) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                            ), 2154)) AS diff_area;
                        """
                        with conn.cursor() as cursor:
                            try:
                                cursor.execute(compare_geom_query)
                                diff_area = cursor.fetchone()[0]
                            except Exception as e:
                                diff_area = -1
                                logging.error(f"             Probleme pour valider les geometries pour com {code_commune} dep {code_departement} mil {millesime} : {e}")
                            if diff_area > 0:
                                # Cas : UPDATE_GEOM
                                # Mettre a jour la geometrie de la commune
                                update_geom_query = f"""
                                    UPDATE reference.communes_unique
                                    SET geom = (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                    WHERE code_commune = '{code_commune}';
                                """
                                save_change_query = f"""
                                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, diff_area_from_previous, old_geom, new_geom)
                                    VALUES ('{code_commune}', '{millesime}', 'geom_update_from_reference', {diff_area},
                                        (SELECT geom FROM reference.communes_unique WHERE code_commune = '{code_commune}'),
                                        (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                    );
                                """
                                with conn.cursor() as cursor:
                                    cursor.execute(update_geom_query)
                                    cursor.execute(save_change_query)
                                logging.info(f"             diff surf : {diff_area}")
                            elif diff_area == 0:
                                # Aucune modification de la geometrie de la commune, pas besoin de mettre a jour, cas : NO_CHANGE_GEOM
                                logging.info(f"             geom no modif")
                    else:
                        logging.error(f"             La geometrie de com {code_commune} n'existe pas dans les communes uniques, ne devrait pas arriver")
            else:
                # CAS : la commune n'existe pas dans le millesime precedent -> NEW
                insert_query = f"""
                    INSERT INTO reference.communes_unique (code_commune, code_departement, nom_commune, created, updated, geom)
                    SELECT id, {code_departement}, COALESCE(nom, 'Nom manquant'), created::timestamp, updated::timestamp, ST_MakeValid(geom)
                    FROM cadastre_{millesime}.{departement_table_name}
                    WHERE id = '{code_commune}';
                """
                insert_geom_query = f"""
                    INSERT INTO historique.communes_changes (code_commune, millesime, new_geom, change_type)
                    SELECT id, '{millesime}', ST_MakeValid(geom), 'created'
                    FROM cadastre_{millesime}.{departement_table_name}
                    WHERE id = '{code_commune}'
                """
                with conn.cursor() as cursor:
                    try :
                        cursor.execute(insert_query)
                        cursor.execute(insert_geom_query)
                        logging.info(f"             com {code_commune} creee.")
                    except Exception as e:
                        logging.warning(f"Probleme pour inserer com {code_commune} dep {code_departement} mil {millesime}, la commune existe déjà, on va faire les vérif avec communes_unique : {e}")
                        # C'est surement dû à un soucis de données brutes, on va donc mettre à jour le nom de la commune car elle existe au final
                        # vérifier le nom / la date de mise à jour / la géométrie
                        select_new_values_query = f"""
                            SELECT COALESCE(nom, 'Nom manquant'), updated::timestamp
                            FROM cadastre_{millesime}.{departement_table_name}
                            WHERE id = '{code_commune}';
                        """
                        select_old_values_query = f"""
                            SELECT nom_commune, updated
                            FROM reference.communes_unique
                            WHERE code_commune = '{code_commune}';
                        """
                        with conn.cursor() as cursor:
                            cursor.execute(select_new_values_query)
                            new_values = cursor.fetchone()
                            cursor.execute(select_old_values_query)
                            old_values = cursor.fetchone()
                        if new_values[0] != old_values[0]:
                            update_name_query = f"""
                                UPDATE reference.communes_unique
                                SET nom_commune = '{new_values[0]}'
                                WHERE code_commune = '{code_commune}';
                            """
                            save_change_query = f"""
                                INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                                VALUES ('{code_commune}', '{millesime}', 'name_update', '{old_values[0]}', '{new_values[0]}');
                            """
                            with conn.cursor() as cursor:
                                cursor.execute(update_name_query)
                                cursor.execute(save_change_query)
                        else:
                            logging.info(f"             nom no modif")
                        if new_values[1] != old_values[1]:
                            if new_values[1] is not None:
                                update_date_query = f"""
                                    UPDATE reference.communes_unique
                                    SET updated = '{new_values[1]}'
                                    WHERE code_commune = '{code_commune}';
                                """
                                save_change_query = f"""
                                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                                    VALUES ('{code_commune}', '{millesime}', 'date_update', '{old_values[1]}', '{new_values[1]}');
                                """
                                with conn.cursor() as cursor:
                                    cursor.execute(update_date_query)
                                    cursor.execute(save_change_query)
                            else:
                                logging.warning(f"             La date de mise a jour de la commune est nulle, ne devrait pas arriver.")
                        else:
                            logging.info(f"             date no modif")
                        # Faire une requête pour comparer les geometries et retourner les m2 de difference
                        compare_geom_query = f"""
                            SELECT ST_Area(ST_Transform(ST_Difference(
                                (SELECT ST_Transform(geom, 2154) FROM reference.communes_unique WHERE code_commune = '{code_commune}'),
                                (SELECT ST_Transform(ST_MakeValid(geom), 2154) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                            ), 2154)) AS diff_area;
                        """
                        with conn.cursor() as cursor:
                            try:
                                cursor.execute(compare_geom_query)
                                diff_area = cursor.fetchone()[0]
                            except Exception as e:
                                diff_area = -1
                                logging.error(f"             Probleme pour valider les geometries pour com {code_commune} dep {code_departement} mil {millesime} : {e}")
                            if diff_area > 0:
                                # Cas : UPDATE_GEOM
                                # Mettre a jour la geometrie de la commune
                                update_geom_query = f"""
                                    UPDATE reference.communes_unique
                                    SET geom = (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                    WHERE code_commune = '{code_commune}';
                                """
                                save_change_query = f"""
                                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, diff_area_from_previous, old_geom, new_geom)
                                    VALUES ('{code_commune}', '{millesime}', 'geom_update', {diff_area},
                                        (SELECT geom FROM reference.communes_unique WHERE code_commune = '{code_commune}'),
                                        (SELECT ST_MakeValid(geom) FROM cadastre_{millesime}.{departement_table_name} WHERE id = '{code_commune}')
                                    );
                                """
                                with conn.cursor() as cursor:
                                    cursor.execute(update_geom_query)
                                    cursor.execute(save_change_query)
                                logging.info(f"             diff surf : {diff_area}")
                            elif diff_area == 0:
                                # Aucune modification de la geometrie de la commune, pas besoin de mettre a jour, cas : NO_CHANGE_GEOM
                                logging.info(f"             geom no modif")
        # On a traite les communes qui sont dans le millesime actuel, on peut maintenant traiter les communes qui ne sont plus actives (presentes dans le millesime precedent mais pas dans le millesime actuel)
        for code_commune, pre_values in actives_commune_in_last_millesime.items():
            if code_commune not in actives_commune_in_current_millesime:
                logging.info(f"             == com {code_commune} dep {code_departement} mil {millesime}")
            
                # Trouver à quelle commune elle a ete fusionnee utiliser le st_contains ou st_within ou st_intersects
                search_fusion_query = f"""
                    SELECT code_commune
                    FROM reference.communes_unique
                    WHERE ST_Contains(geom, (SELECT ST_Centroid(geom) FROM reference.communes_unique WHERE code_commune = '{code_commune}'))
                    AND code_commune != '{code_commune}';
                """
                with conn.cursor() as cursor:
                    cursor.execute(search_fusion_query)
                    fusioned_to = cursor.fetchone()
                change_type = "inactive"
                if fusioned_to:
                    fusioned_to = fusioned_to[0]
                    update_fusioned_query = f"""
                        UPDATE reference.communes_unique
                        SET fusioned_to = '{fusioned_to}'
                        WHERE code_commune = '{code_commune}';
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(update_fusioned_query)
                    save_change_query = f"""
                        INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                        VALUES ('{code_commune}', '{millesime}', 'fusioned_to', NULL, '{fusioned_to}');
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(save_change_query)
                    logging.info(f"             com {code_commune} a ete fusionnee avec com {fusioned_to}.")
                else :
                    # La commune n'a pas fusionnee car certainement elle n'est pas dans ce millesime par erreur, on est donc oblige de tester les autres millesimes
                    # Faire une requête pour trouver dans quel millesime cette commune reapparait
                    # On est oblige de tester les autres schemas cadastre_* pour trouver la commune et le millesime
                    # On va donc regarder dans tout les schemas cadastre_* et la table communes_{code_departement} pour trouver dans quel millesime la commune reapparait
                    # Si aucun millesime n'est trouve, on considère que la commune a ete supprimee, mais on ne devrait pas arriver a ne pas retrouver avec quelle commune elle a ete fusionnee
                    logging.info(f"             fusion non trouvee, malgre l'inactivite de la commune, on va chercher dans les autres millesimes pour verifier qu'elle n'existe pas juste par erreur dans ce millesime.")
                    search_millesime_query = f"""
                        SELECT schema_name
                        FROM information_schema.schemata
                        WHERE schema_name LIKE 'cadastre_%'
                        AND schema_name > 'cadastre_{millesime}'
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(search_millesime_query)
                        schemas = [row[0] for row in cursor.fetchall()]
                    change_type = "inactive_no_fusion"
                    # Tant qu'on a pas trouve la commune dans un millesime, on continue de chercher
                    for schema_name in schemas:
                        search_commune_query = f"""
                            SELECT id
                            FROM {schema_name}.{departement_table_name}
                            WHERE id = '{code_commune}';
                        """
                        with conn.cursor() as cursor:
                            cursor.execute(search_commune_query)
                            commune = cursor.fetchone()
                        if commune:
                            logging.info(f"             com {code_commune} trouvee dans le millesime {schema_name.replace('cadastre_', '')}.")
                            # On a trouve la commune, on va verifier si la geometrie est la même entre le millesime actuel et le millesime trouve
                            search_geom_query = f"""
                                SELECT ST_Area(ST_Transform(ST_Difference(
                                    (SELECT ST_Transform(geom, 2154) FROM reference.communes_unique WHERE code_commune = '{code_commune}'),
                                    (SELECT ST_Transform(ST_MakeValid(geom), 2154) FROM {schema_name}.{departement_table_name} WHERE id = '{code_commune}')
                                ), 2154)) AS diff_area;
                            """
                            with conn.cursor() as cursor:
                                try:
                                    cursor.execute(search_geom_query)
                                    diff_area = cursor.fetchone()[0]
                                except Exception as e:
                                    diff_area = -1
                                    logging.error(f"             Probleme pour valider les geometries pour com {code_commune} dep {code_departement} mil {millesime} : {e}")
                                if diff_area > 0 or diff_area == 0:
                                    # Ne rien faire car la commune existe donc toujours et n'a pas ete fusionnee
                                    change_type = "no_present_in_millesime_but_still_active_and_present_in_other_millesime"
                                    logging.warning(f"             com {code_commune} est toujours active et presente dans un autre millesime, surement une erreur de donnees brute. On ne peut rien y faire.")
                                    break
                        else:
                            # On a pas trouve la commune dans ce millesime, on continue de chercher
                            continue
                    if change_type == "inactive_no_fusion":
                        # On a pas trouve la commune dans un autre millesime, on considère que la commune a ete supprimee
                        logging.warning(f"             verifications dans tous les millesimes, com {code_commune} non trouvee, on considere qu'elle a ete supprimee, même si on n'a pas trouve avec quelle commune elle a ete fusionnee.")
                        # Vérification de fusion, on va chercher si la commune a été fusionnée avec une autre commune dans un autre millesime
                        # C'est possible que la géométrie n'a été mis à jour que dans un autre millesime que l'actuel
                        # Il faut comparer la géométrie de la commune du millesime actuel avec la géométrie de la commune d'un autre millesime
                        # On va donc regarder dans tout les schemas cadastre_* et la table communes_{code_departement} pour trouver dans quel millesime la commune reapparait
                        # Si aucun millesime n'est trouve, on considère que la commune a ete supprimee, mais on ne devrait pas arriver a ne pas retrouver avec quelle commune elle a ete fusionnee
                        for schema_name in schemas:
                            search_fusion_in_other_millesime_query = f"""
                                SELECT id
                                FROM {schema_name}.communes_{code_departement}
                                WHERE ST_Contains(geom, (SELECT ST_Centroid(geom) FROM reference.communes_unique WHERE code_commune = '{code_commune}'))
                                AND id != '{code_commune}';
                            """
                            with conn.cursor() as cursor:
                                cursor.execute(search_fusion_in_other_millesime_query)
                                fusioned_to = cursor.fetchone()
                            fusionned_millesime = schema_name.replace("cadastre_", "")
                            if fusioned_to:
                                fusioned_to = fusioned_to[0]
                                logging.info(f"             com {code_commune} fusionnee avec com {fusioned_to} trouvé dans le millesime {fusionned_millesime}.")
                                update_fusioned_query = f"""
                                    UPDATE reference.communes_unique
                                    SET fusioned_to = '{fusioned_to}'
                                    WHERE code_commune = '{code_commune}';
                                """
                                # logguer le changement
                                save_change_query = f"""
                                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                                    VALUES ('{code_commune}', '{millesime}', 'fusioned_to_in_{fusionned_millesime}', NULL, '{fusioned_to}');
                                """
                                with conn.cursor() as cursor:
                                    cursor.execute(update_fusioned_query)
                                    cursor.execute(save_change_query)

                                change_type = f"inactive_fusioned_in_{fusionned_millesime}"

                                # Ca veut dire que la commune fusioned_to n'a pas sa geometrie mise a jour dans le millesime actuel
                                # On va donc mettre a jour la geometrie de la commune fusioned_to
                                update_geom_query = f"""
                                    UPDATE reference.communes_unique
                                    SET geom = (SELECT ST_MakeValid(geom) FROM {schema_name}.{departement_table_name} WHERE id = '{fusioned_to}')
                                    WHERE code_commune = '{fusioned_to}';
                                """
                                # Informer que la commune fusioned_to a eu sa geometrie mise a jour dans le millesime actuel
                                # mais que cette geometrie n'a quand même pas ete mise a jour dans le millesime actuel dans les données brutes
                                # on force donc la mise a jour de la geometrie de la commune fusioned_to d'après le millesime fusionned_millesime dans le millesime actuel
                                # pour savoir que c'est dans ce millesime et non réelement dans le millesime de fusion qu'elle a été fusionnée (ça sera considére comme pas de changement de geometrie quand on traitera le millesime de fusion)
                                save_change_query = f"""
                                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, diff_area_from_previous, old_geom, new_geom)
                                    VALUES ('{fusioned_to}', '{millesime}', 'geom_update_from_{fusionned_millesime}',
                                        (SELECT ST_Area(ST_Transform(ST_Difference(
                                            (SELECT ST_Transform(geom, 2154) FROM reference.communes_unique WHERE code_commune = '{fusioned_to}'),
                                            (SELECT ST_Transform(ST_MakeValid(geom), 2154) FROM {schema_name}.{departement_table_name} WHERE id = '{fusioned_to}')
                                        ), 2154)) AS diff_area),
                                        (SELECT geom FROM reference.communes_unique WHERE code_commune = '{fusioned_to}'),
                                        (SELECT ST_MakeValid(geom) FROM {schema_name}.{departement_table_name} WHERE id = '{fusioned_to}')
                                    );
                                """
                                with conn.cursor() as cursor:
                                    cursor.execute(update_geom_query)
                                    cursor.execute(save_change_query)
                                break
                            else:
                                logging.info(f"             pas de fusion trouvee dans le millesime {fusionned_millesime}, on continue de chercher.")
                                continue
                        if change_type == "inactive_no_fusion":
                            logging.error(f"             La commune {code_commune} n'a pas ete fusionnee avec une autre commune, ne devrait pas arriver.")
                # Mettre a jour le statut de la commune, cas : INACTIVE
                # cas inactive ou inactive_no_fusion ou commence par inactive_fusioned_in_ (pour les communes fusionnees depuis un millesime futur)
                if change_type == "inactive" or change_type == "inactive_no_fusion" or change_type.startswith("inactive_fusioned_in_"):
                    update_status_query = f"""
                        UPDATE reference.communes_unique
                        SET status = '{change_type}'
                        WHERE code_commune = '{code_commune}';
                    """
                    with conn.cursor() as cursor:
                        cursor.execute(update_status_query)

                # On sauvegarde le changement dans l'historique pour comprendre ce qui s'est passe
                save_change_query = f"""
                    INSERT INTO historique.communes_changes (code_commune, millesime, change_type, old_value, new_value)
                    VALUES ('{code_commune}', '{millesime}', '{change_type}', NULL, NULL);
                """
                with conn.cursor() as cursor:
                    cursor.execute(save_change_query)
                logging.info(f"             com {code_commune} est devenue {change_type} mil {millesime}.")
            else:
                # La commune est toujours active, on ne fait rien
                logging.info(f"             com {code_commune} est toujours active mil {millesime}.")
                pass
    else:
        # On traite le premier millesime donc on ne fait que des insertions
        # Toutes les communes seront donc considerees comme actives
        insert_query = f"""
            INSERT INTO reference.communes_unique (code_commune, code_departement, nom_commune, created, updated, geom)
            SELECT id, '{code_departement}', COALESCE(nom, 'Nom manquant'), created::timestamp, updated::timestamp, ST_MakeValid(geom)
            FROM cadastre_{millesime}.{departement_table_name};
        """
        with conn.cursor() as cursor:
            cursor.execute(insert_query)
        logging.info(f"           Insertion com pour dep {code_departement} mil {millesime}.")

        # On push les geometries qui feront statut de reference
        # etape 1 : Inserer les donnees avec gestion des conflits
        insert_geom_query = f"""
            INSERT INTO historique.communes_changes (code_commune, millesime, new_geom, change_type)
            SELECT id, '{millesime}', ST_MakeValid(geom), 'created'
            FROM cadastre_{millesime}.{departement_table_name};
        """
        with conn.cursor() as cursor:
            cursor.execute(insert_geom_query)
        logging.info(f"           Insertion geom pour dep {code_departement} mil {millesime}.")

    # Dans les deux cas on met a jour les statistiques du nombre de communes pour le departement mil
    insert_stats_query = f"""
        INSERT INTO stats.stats_communes (millesime, code_departement, nb_communes)
        SELECT '{millesime}', '{code_departement}', COUNT(*)
        FROM cadastre_{millesime}.{departement_table_name};
    """
    with conn.cursor() as cursor:
        cursor.execute(insert_stats_query)


def process_all_millesimes():
    """Traiter tous les millesimes disponibles"""
    conn = connect_db()
    if not conn:
        return

    create_tables(conn)

    # Recuperer tous les schemas de type cadastre_*
    query_schemas = "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'cadastre_%';"


    with conn.cursor() as cursor:
        cursor.execute(query_schemas)
        schemas = [row[0] for row in cursor.fetchall()]

    # Trier les schemas par date (extraire et trier les millesimes)
    sorted_schemas = sorted(schemas, key=lambda x: x.replace("cadastre_", ""))
    previous_millesime = None
    for schema_name in sorted_schemas:
        millesime = schema_name.replace("cadastre_", "")
        logging.info(f" ===== Traitement du millesime {millesime}")

        # Recuperation des tables communes_*
        query_list_departements_tables = f"""
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = '{schema_name}' AND table_name LIKE 'communes_%';
            """
        with conn.cursor() as cursor:
            cursor.execute(query_list_departements_tables)
            departements_tables = [row[0] for row in cursor.fetchall()]

            
        logging.info(f"       Nombres de tables de communes dans le schema {schema_name} : {len(departements_tables)}")

        for departement_table in departements_tables:
            logging.info(f"       === Traitement dep, table {departement_table} dans le schema {schema_name}")

            process_communes_by_dep(conn, departement_table, millesime, previous_millesime)

            # Mettre à jour le millesime precedent
        previous_millesime = millesime

    conn.close()

if __name__ == "__main__":
    process_all_millesimes()
