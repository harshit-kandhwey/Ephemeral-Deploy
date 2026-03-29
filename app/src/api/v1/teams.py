from flask import request, jsonify
from flask_jwt_extended import jwt_required
from sqlalchemy.exc import IntegrityError
from . import api_v1
from ...extensions import db
from ...models.team import Team
from ...utils.decorators import role_required


@api_v1.route("/teams", methods=["GET"])
@jwt_required()
def get_teams():
    """
    Get all teams
    ---
    tags:
      - Teams
    security:
      - Bearer: []
    responses:
      200:
        description: List of teams
    """
    teams = Team.query.all()
    return jsonify({"teams": [t.to_dict() for t in teams], "count": len(teams)}), 200


@api_v1.route("/teams/<int:team_id>", methods=["GET"])
@jwt_required()
def get_team(team_id):
    """Get team by ID"""
    team = Team.query.get_or_404(team_id)
    return jsonify(team.to_dict()), 200


@api_v1.route("/teams", methods=["POST"])
@jwt_required()
@role_required(["admin"])
def create_team():
    """
    Create a new team (admin only)
    ---
    tags:
      - Teams
    security:
      - Bearer: []
    parameters:
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - name
          properties:
            name:
              type: string
            description:
              type: string
    responses:
      201:
        description: Team created
      400:
        description: Validation error
    """
    data = request.get_json()
    if not data or "name" not in data:
        return jsonify({"error": "Name is required"}), 400

    team = Team(name=data["name"], description=data.get("description", ""))
    db.session.add(team)
    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        return jsonify({"error": "Team name already exists"}), 409
    return jsonify(team.to_dict()), 201


@api_v1.route("/teams/<int:team_id>", methods=["PUT"])
@jwt_required()
@role_required(["admin"])
def update_team(team_id):
    """Update team (admin only)"""
    team = Team.query.get_or_404(team_id)
    data = request.get_json(silent=True)

    if not data:
        return jsonify({"error": "No data provided"}), 400

    # Validate name uniqueness if name is being updated
    if "name" in data:
        existing_team = (
            Team.query.filter_by(name=data["name"]).filter(Team.id != team.id).first()
        )
        if existing_team:
            return jsonify({"error": "Team name already exists"}), 409

    # Update fields after validation passes
    if "name" in data:
        team.name = data["name"]
    if "description" in data:
        team.description = data["description"]

    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        return jsonify({"error": "Team name already exists"}), 409
    return jsonify(team.to_dict()), 200
