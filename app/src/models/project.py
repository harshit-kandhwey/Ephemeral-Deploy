from datetime import datetime
from ..extensions import db


class Project(db.Model):
    __tablename__ = 'projects'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text)
    # active, archived, on_hold
    status = db.Column(db.String(20), default='active')
    team_id = db.Column(db.Integer, db.ForeignKey('teams.id'), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(
        db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # Relationships
    team = db.relationship('Team', back_populates='projects')
    tasks = db.relationship(
        'Task', back_populates='project', cascade='all, delete-orphan')

    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'status': self.status,
            'team_id': self.team_id,
            'team_name': self.team.name if self.team else None,
            'task_count': len(self.tasks),
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat()
        }
