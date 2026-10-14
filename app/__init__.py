# Kept free of third-party imports: service.py imports app.config before it
# reports START_PENDING and before uvicorn and FastAPI are loaded.
__version__ = "0.1.0"
