import logging
import os
from flask import Flask, request


logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()

PROJECT_ID = os.environ.get("PROJECT_ID", "")
# just the ID not the projects/project-id replace if exists
PROJECT_ID = PROJECT_ID.replace("projects/", "")


flask_app = Flask(__name__)


@flask_app.route("/", methods=["GET"])
def hello_world():
    # a simple hello to help debug cloud run url access
    name = os.environ.get("NAME", "World")
    return "HELLO {}!".format(name)
