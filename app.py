from flask import Flask, request, jsonify, render_template, send_from_directory, g
import sqlite3
import os

app = Flask(__name__, static_folder='static', template_folder='templates')

def init_db():
    with app.app_context():
        conn = get_db()
        with app.open_resource('sqlitetree.sql') as f:
            conn.executescript(f.read().decode('utf8'))
        conn.commit()

def get_db():
    if 'db' not in g:
        g.db = sqlite3.connect('tree.db')
        g.db.row_factory = sqlite3.Row
    return g.db

@app.teardown_appcontext
def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()

# Initialize database on first request
@app.before_request
def initialize():
    if not hasattr(app, 'initialized'):
        init_db()
        app.initialized = True

# Initialize database on first request
@app.before_request
def initialize():
    if not hasattr(app, 'initialized'):
        init_db()
        app.initialized = True

@app.route('/')
def index():
    return render_template('index.html')

# Serve static files
@app.route('/static/<path:filename>')
def serve_static(filename):
    return send_from_directory(app.static_folder, filename)


# API routes
@app.route('/api/tree', methods=['GET'])
def get_tree():
    conn = get_db()
    tree = conn.execute('SELECT * FROM tree ORDER BY tree_id, lft').fetchall()
    return jsonify([dict(node) for node in tree])

@app.route('/api/trees', methods=['GET'])
def get_trees():
    conn = get_db()
    trees = conn.execute('SELECT DISTINCT name FROM tree WHERE level = 0 ORDER BY tree_id').fetchall()
    return jsonify([dict(tree) for tree in trees])

@app.route('/api/trees', methods=['POST'])
def create_tree():
    data = request.get_json()
    name = data.get('name', 'New Tree')
    try:
        conn = get_db()
        conn.execute('INSERT INTO add_root_operation (name) VALUES (?)', (name,))
        last_id = conn.execute('SELECT id FROM last_operation_id WHERE operation_name = "add_root" ORDER BY id DESC LIMIT 1').fetchone()['id']
        conn.execute('DELETE FROM last_operation_id WHERE id = ?', (last_id,))
        conn.commit()
        return jsonify({'success': True, 'id': last_id}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400


@app.route('/api/trees/<int:tree_id>/nodes', methods=['GET'])
def get_tree_nodes(tree_id):
    conn = get_db()
    nodes = conn.execute('''
        SELECT id, tree_id, name, lft, rgt, level 
        FROM tree WHERE tree_id = ? ORDER BY lft
    ''', (tree_id,)).fetchall()
    return jsonify([dict(node) for node in nodes])

@app.route('/api/trees/<int:tree_id>/nodes', methods=['POST'])
def add_node(tree_id):
    data = request.get_json()
    conn = get_db()
    
    try:
        conn.execute('''
            INSERT INTO add_node_operation (tree_id, target_node_id, name, position)
            VALUES (?, ?, ?, ?)
        ''', (tree_id, data['target_node_id'], data['name'], data['position']))
        last_id = conn.execute('SELECT id FROM last_operation_id WHERE operation_name = "add_node" ORDER BY id DESC LIMIT 1').fetchone()['id']
        conn.execute('DELETE FROM last_operation_id WHERE id = ?', (last_id,))
        conn.commit()
        return jsonify({'success': True, 'id': last_id}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400
    

@app.route('/api/trees/<int:tree_id>/nodes/move', methods=['POST'])
def move_node(tree_id):
    data = request.get_json()
    conn = get_db()
    
    try:
        conn.execute('''
            INSERT INTO move_node_operation (tree_id, target_node_id, node_id, position)
            VALUES (?, ?, ?, ?)
        ''', (tree_id, data['target_node_id'], data['node_id'], data['position']))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400
        conn.close()


if __name__ == '__main__':
    app.run(debug=True)