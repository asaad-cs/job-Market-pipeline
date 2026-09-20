import json
import os
from datetime import datetime, timezone

from azure.storage.filedatalake import DataLakeServiceClient
from dotenv import load_dotenv

load_dotenv()


def upload_raw_to_adls(source: str, raw_records: list[dict]) -> str:
    """
    Upload collected raw records as a JSON file to the ADLS Gen2 raw container.
    Returns the uploaded file path.
    """

    connection_string = os.getenv("AZURE_STORAGE_CONNECTION_STRING")
    file_system = os.getenv("AZURE_STORAGE_FILE_SYSTEM", "raw")

    if not connection_string:
        raise RuntimeError(
            "AZURE_STORAGE_CONNECTION_STRING is not configured."
        )

    service_client = DataLakeServiceClient.from_connection_string(
        connection_string
    )

    file_system_client = service_client.get_file_system_client(
        file_system
    )

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    file_name = f"{source}_saudi_jobs_{timestamp}.json"

    data = json.dumps(
        raw_records,
        ensure_ascii=False,
        indent=2,
    )

    file_client = file_system_client.get_file_client(file_name)

    file_client.upload_data(
        data.encode("utf-8"),
        overwrite=True,
    )

    return f"{file_system}/{file_name}"