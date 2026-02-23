"""
Run the application locally for development
Usage: python run.py
"""
from app.src import create_app

if __name__ == '__main__':
    app = create_app('development')
    app.run(host='0.0.0.0', port=5000, debug=True)
