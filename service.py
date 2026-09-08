"""
service.py — minimal Flask wrapper exposing routing.py's
route_message() as an HTTP endpoint, for the Pascal shell to call.
This stands in for wherever letigo.py's logic would eventually live.
"""
from flask import Flask, request, jsonify
from routing import route_message

app = Flask(__name__)

@app.route("/route", methods=["POST"])
def route():
    data = request.get_json(force=True)
    message = data.get("message", "")
    output_type = route_message(message)
    return jsonify({
        "message": message,
        "output_type": output_type,
        "source": "prolog+nlp pipeline"
    })

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5001)