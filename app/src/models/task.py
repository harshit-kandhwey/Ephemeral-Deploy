from datetime import datetime
from ..extensions import db


class Task(db.Model):
    __tablename__ = 'tasks'

    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text)
    # todo, in_progress, in_review, done
    status = db.Column(db.String(20), default='todo')
    # low, medium, high, critical
    priority = db.Column(db.String(20), default='medium')

    # Foreign keys
    project_id = db.Column(db.Integer, db.ForeignKey(
        'projects.id'), nullable=False)
    creator_id = db.Column(
        db.Integer, db.ForeignKey('users.id'), nullable=False)
    assignee_id = db.Column(db.Integer, db.ForeignKey('users.id'))

    # Dates
    due_date = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(
        db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    completed_at = db.Column(db.DateTime)

    # Relationships
    project = db.relationship('Project', back_populates='tasks')
    creator = db.relationship(
        'User', back_populates='created_tasks', foreign_keys=[creator_id])
    assignee = db.relationship(
        'User', back_populates='assigned_tasks', foreign_keys=[assignee_id])
    comments = db.relationship(
        'Comment', back_populates='task', cascade='all, delete-orphan')
    attachments = db.relationship(
        'Attachment', back_populates='task', cascade='all, delete-orphan')

    def to_dict(self, include_comments=False):
        data = {
            'id': self.id,
            'title': self.title,
            'description': self.description,
            'status': self.status,
            'priority': self.priority,
            'project_id': self.project_id,
            'project_name': self.project.name if self.project else None,
            'creator': self.creator.to_dict() if self.creator else None,
            'assignee': self.assignee.to_dict() if self.assignee else None,
            'due_date': self.due_date.isoformat() if self.due_date else None,
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat(),
            'completed_at': self.completed_at.isoformat() if self.completed_at else None,
            'comment_count': len(self.comments),
            'attachment_count': len(self.attachments)
        }

        if include_comments:
            data['comments'] = [c.to_dict() for c in self.comments]
            data['attachments'] = [a.to_dict() for a in self.attachments]

        return data
    
