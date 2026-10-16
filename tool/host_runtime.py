"""Stable launcher: graceful shutdown works without a Windows console signal."""
import os
from pathlib import Path
import threading
import time

import uvicorn


def main():
    # Held through lifespan shutdown, even after the listening socket closes.
    from host_release_agent import exclusive_lock
    with exclusive_lock(os.environ["PDF_VIEWER_RUNTIME_LOCK"]):
        serve()


def serve():
    server = uvicorn.Server(uvicorn.Config(
        "server.main:app", host=os.environ["MEDIA_SERVER_HOST"],
        port=int(os.environ["MEDIA_SERVER_PORT"]), timeout_graceful_shutdown=60,
    ))
    stop = Path(os.environ["PDF_VIEWER_STOP_FILE"])

    def watch():
        while not stop.exists():
            time.sleep(0.25)
        server.should_exit = True

    threading.Thread(target=watch, daemon=True).start()
    server.run()


if __name__ == "__main__":
    main()
