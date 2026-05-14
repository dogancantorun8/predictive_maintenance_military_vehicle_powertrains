-- PostgreSQL initialization script
-- Creates dedicated databases for MLflow metadata and KFP metadata.
-- Run automatically by the postgres container on first startup.

CREATE DATABASE mlflow;
CREATE DATABASE kfp;
