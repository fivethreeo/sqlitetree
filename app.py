from flask import Flask, request, jsonify, render_template, send_from_directory, g, session, redirect, url_for, flash
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, SubmitField
from wtforms.validators import DataRequired, Email, Length
from werkzeug.security import generate_password_hash, check_password_hash
import sqlite3
import os
import secrets
import smtplib
from email.message import EmailMessage

from itsdangerous import URLSafeTimedSerializer
from datetime import datetime, timedelta
import pytz  # for timezone handling
# use env file for sensitive info in production
from dotenv import load_dotenv
from flask_babel import Babel, lazy_gettext as _

load_dotenv()

app = Flask(__name__, static_folder='static', template_folder='templates')
# Configuration

# Babel configuration
app.config['BABEL_DEFAULT_LOCALE'] = 'nb_NO'
app.config['BABEL_SUPPORTED_LOCALES'] = ['nb_NO', 'en']
app.config['BABEL_TRANSLATION_DIRECTORIES'] = 'translations'

app.secret_key = os.getenv("SECRET_KEY") or 'dev_key'

# Email configuration (update these with your SMTP settings)
app.config['MAIL_SERVER'] = os.getenv('MAIL_SERVER')
app.config['MAIL_PORT'] = os.getenv('MAIL_PORT')
app.config['MAIL_USE_TLS'] = True
app.config['MAIL_USERNAME'] = os.getenv('MAIL_USERNAME')
app.config['MAIL_PASSWORD'] = os.getenv('MAIL_PASSWORD')
app.config['MAIL_DEFAULT_SENDER'] = os.getenv('MAIL_DEFAULT_SENDER')

# Timezone configuration
app.config['TIMEZONE'] = os.getenv('TIMEZONE', 'UTC')

def get_locale():
    # You can also use request.accept_languages to determine the best match
    return request.accept_languages.best_match(app.config['BABEL_SUPPORTED_LOCALES'])

babel = Babel(app, locale_selector=get_locale)

class RegistrationForm(FlaskForm):
    username = StringField(_('Username'), validators=[DataRequired(), Length(min=3, max=20)])
    email = StringField(_('Email'), validators=[DataRequired(), Email()])
    password = PasswordField(_('Password'), validators=[DataRequired(), Length(min=6)])
    submit = SubmitField(_('Register'))

class LoginForm(FlaskForm):
    username = StringField(_('Username'), validators=[DataRequired()])
    password = PasswordField(_('Password'), validators=[DataRequired()])
    submit = SubmitField(_('Log In'))

class ForgotPasswordForm(FlaskForm):
    email = StringField(_('Email'), validators=[DataRequired(), Email()])
    submit = SubmitField(_('Send Reset Link'))

class ResetPasswordForm(FlaskForm):
    password = PasswordField(_('New Password'), validators=[DataRequired(), Length(min=6)])
    confirm_password = PasswordField(_('Confirm New Password'), validators=[DataRequired(), Length(min=6)])
    submit = SubmitField(_('Reset Password'))

def init_db():
    with app.app_context():
        conn = get_db()
        with app.open_resource('schema.sql') as f:
            conn.executescript(f.read().decode('utf8'))
        conn.commit()

def get_db():
    if 'db' not in g:
        g.db = sqlite3.connect('app.db')
        g.db.row_factory = sqlite3.Row
    return g.db

@app.teardown_appcontext
def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()

@app.before_request
def initialize():
    if not hasattr(app, 'initialized'):
        init_db()
        app.initialized = True

def get_current_time():
    """Get current time in configured timezone"""
    tz = pytz.timezone(app.config['TIMEZONE'])
    return datetime.now(tz)

def parse_db_datetime(dt_string):
    """Parse datetime string from database with timezone awareness"""
    if dt_string is None:
        return None
    
    # Try parsing as ISO format with timezone
    try:
        return datetime.fromisoformat(dt_string.replace('Z', '+00:00'))
    except ValueError:
        # Fallback: assume UTC if no timezone info
        naive_dt = datetime.strptime(dt_string, '%Y-%m-%d %H:%M:%S')
        return pytz.utc.localize(naive_dt)

def is_token_expired(token_created, expiration_hours):
    """Check if token is expired with timezone awareness"""
    current_time = get_current_time()
    
    # Ensure both datetimes are timezone-aware
    if token_created.tzinfo is None:
        token_created = pytz.utc.localize(token_created)
    
    # Convert both to UTC for comparison
    token_created_utc = token_created.astimezone(pytz.utc)
    current_time_utc = current_time.astimezone(pytz.utc)
    
    time_diff = current_time_utc - token_created_utc
    return time_diff > timedelta(hours=expiration_hours)

def send_verification_email(email, token):
    """Send verification email with token"""
    try:
        verification_url = f"http://localhost:5000/verify-email/{token}"
        
        message = EmailMessage()
        message['From'] = app.config['MAIL_DEFAULT_SENDER']
        message['To'] = email
        message['Subject'] = str(_('Verify Your Email Address'))
        
        body = str(f"""
        <h2>{_('Welcome to Tree Manager!')}</h2>
        <p>{_('Please click the link below to verify your email address:')}</p>
        <p><a href="{verification_url}">{verification_url}</a></p>
        <p>{_('This link will expire in 24 hours.')}</p>
        <br>
        <p>{_('If you did not create an account, please ignore this email.')}</p>
        """)

        message.set_content(body, subtype='html')
        
        with smtplib.SMTP(app.config['MAIL_SERVER'], app.config['MAIL_PORT']) as server:
            server.starttls()
            server.login(app.config['MAIL_USERNAME'], app.config['MAIL_PASSWORD'])
            server.send_message(message)
        
        return True
    except Exception as e:
        print(f"Error sending email: {e}")
        return False

def generate_verification_token():
    """Generate a secure random token"""
    return secrets.token_urlsafe(32)

@app.route('/')
def index():
    if 'user_id' not in session:
        return redirect(url_for('login'))
    return render_template('index.html')

@app.route('/register', methods=['GET', 'POST'])
def register():
    form = RegistrationForm()
    if form.validate_on_submit():
        conn = get_db()
        try:
            # Check if username already exists
            existing_user = conn.execute(
                'SELECT id FROM users WHERE username = ?', (form.username.data,)
            ).fetchone()
            
            if existing_user:
                flash('Username already exists.', 'error')
                return render_template("register.html", form=form)
            
            # Check if email already exists
            existing_email = conn.execute(
                'SELECT id FROM users WHERE email = ?', (form.email.data,)
            ).fetchone()
            
            if existing_email:
                flash('Email already registered.', 'error')
                return render_template("register.html", form=form)
            
            # Hash password and insert new user (initially inactive)
            hashed_password = generate_password_hash(form.password.data)
            cursor = conn.execute(
                'INSERT INTO users (username, email, password, is_active) VALUES (?, ?, ?, ?)',
                (form.username.data, form.email.data, hashed_password, False)
            )
            user_id = cursor.lastrowid
            
            # Generate verification token
            token = generate_verification_token()
            conn.execute(
                'INSERT INTO registration_tokens (token, user_id) VALUES (?, ?)',
                (token, user_id)
            )
            
            conn.commit()
            
            # Send verification email
            if send_verification_email(form.email.data, token):
                flash(_('Registration successful! Please check your email to verify your account.'), 'success')
            else:
                flash(_('Registration successful but failed to send verification email. Please contact support.'), 'warning')

            return redirect(url_for('login'))
            
        except Exception as e:
            # log_error
            print(f"Error during registration: {e}")
            conn.rollback()
            flash(_('An error occurred during registration.'), 'error')

    return render_template("register.html", form=form)

@app.route('/verify-email/<token>')
def verify_email(token):
    conn = get_db()
    try:
        # Get token record
        token_record = conn.execute(
            'SELECT * FROM registration_tokens WHERE token = ?', (token,)
        ).fetchone()
        
        if not token_record:
            flash('Invalid verification token.', 'error')
            return redirect(url_for('login'))
        
        # Check if token is expired (24 hours)
        token_created = parse_db_datetime(token_record['created_at'])
        if is_token_expired(token_created, 24):
            flash('Verification token has expired.', 'error')
            return redirect(url_for('login'))
        
        # Verify the user
        conn.execute(
            'UPDATE users SET is_active = 1 WHERE id = ?', (token_record['user_id'],)
        )
        
        # Delete used token
        conn.execute(
            'DELETE FROM registration_tokens WHERE token = ?', (token,)
        )
        
        conn.commit()
        flash(_('Email verified successfully! You can now log in.'), 'success')
        return redirect(url_for('login'))
        
    except Exception as e:
        print(f"Error verifying email: {e}")
        conn.rollback()
        flash('Error verifying email.', 'error')
        return redirect(url_for('login'))

def send_password_reset_email(email, token):
    """Send password reset email with token"""
    try:
        reset_url = f"http://localhost:5000/reset-password/{token}"
        
        message = MIMEMultipart()
        message['To'] = email
        message['Subject'] = _('Password Reset Request')
        
        body = f"""
        <h2>{_('Password Reset Request')}</h2>
        <p>{_('You requested to reset your password. Click the link below to set a new password:')}</p>
        <p><a href="{reset_url}">{reset_url}</a></p>
        <p>{_('This link will expire in 1 hour.')}</p>
        <br>
        <p>{_('If you did not request a password reset, please ignore this email.')}</p>
        """
        
        message.attach(MIMEText(body, 'html'))
        
        with smtplib.SMTP(app.config['MAIL_SERVER'], app.config['MAIL_PORT']) as server:
            server.starttls()
            server.login(app.config['MAIL_USERNAME'], app.config['MAIL_PASSWORD'])
            server.send_message(message)
        
        return True
    except Exception as e:
        print(f"Error sending password reset email: {e}")
        return False
    
@app.route('/forgot-password', methods=['GET', 'POST'])
def forgot_password():
    form = ForgotPasswordForm()
    if form.validate_on_submit():
        conn = get_db()
        
        user = conn.execute(
            'SELECT * FROM users WHERE email = ?', (form.email.data,)
        ).fetchone()
        
        if user:
            if not user['is_active']:
                flash(_('Please verify your email before resetting your password.'), 'error')
                return render_template("forgot_password.html", form=form)
            
            # Delete old password reset tokens for this user
            conn.execute(
                'DELETE FROM password_reset_tokens WHERE user_id = ?', (user['id'],)
            )
            
            # Generate new token
            token = generate_verification_token()
            conn.execute(
                'INSERT INTO password_reset_tokens (token, user_id) VALUES (?, ?)',
                (token, user['id'])
            )
            
            conn.commit()
            
            if send_password_reset_email(form.email.data, token):
                flash(_('Password reset link sent! Please check your email.'), 'success')
            else:
                flash(_('Failed to send password reset email. Please try again later.'), 'error')

            return redirect(url_for('login'))
        else:
            flash(_('Email not found.'), 'error')

    return render_template('forgot_password.html', form=form)

@app.route('/reset-password/<token>', methods=['GET', 'POST'])
def reset_password(token):
    form = ResetPasswordForm()
    conn = get_db()
    
    # Validate token
    token_record = conn.execute(
        'SELECT * FROM password_reset_tokens WHERE token = ?', (token,)
    ).fetchone()
    
    if not token_record:
        flash(_('Invalid or expired password reset token.'), 'error')
        return redirect(url_for('login'))
    
    # Check if token is expired (1 hour)
    token_created = parse_db_datetime(token_record['created_at'])
    if is_token_expired(token_created, 1):
        flash(_('Password reset token has expired.'), 'error')
        return redirect(url_for('forgot_password'))
    
    if form.validate_on_submit():
        if form.password.data != form.confirm_password.data:
            flash(_('Passwords do not match.'), 'error')
            return render_template('reset_password.html', form=form, token=token)
        
        try:
            # Hash new password
            hashed_password = generate_password_hash(form.password.data)
            
            # Update user password
            conn.execute(
                'UPDATE users SET password = ? WHERE id = ?',
                (hashed_password, token_record['user_id'])
            )
            
            # Delete used token
            conn.execute(
                'DELETE FROM password_reset_tokens WHERE token = ?', (token,)
            )
            
            conn.commit()

            flash(_('Password reset successfully! You can now log in with your new password.'), 'success')
            return redirect(url_for('login'))
            
        except Exception as e:
            conn.rollback()
            flash(_('Error resetting password.'), 'error')

    return render_template('reset_password.html', form=form, token=token)

@app.route('/login', methods=['GET', 'POST'])
def login():
    form = LoginForm()
    if form.validate_on_submit():
        conn = get_db()
        # allow login with either username or email
        user = conn.execute(
            'SELECT * FROM users WHERE username = ? OR email = ?', (form.username.data, form.username.data)
        ).fetchone()
        
        if user and check_password_hash(user['password'], form.password.data):
            if not user['is_active']:
                flash(_('Please verify your email before logging in.'), 'error')
                return render_template("login.html", form=form)
            
            session["user_id"] = user['id']
            session["username"] = user['username']
            flash(_('Login successful!'), 'success')
            return redirect(url_for('index'))
        else:
            flash(_('Invalid username or password.'), 'error')

    return render_template("login.html", form=form)

@app.route('/logout')
def logout():
    session.clear()
    flash(_('You have been logged out.'), 'success')
    return redirect(url_for('login'))

@app.route('/resend-verification', methods=['GET', 'POST'])
def resend_verification():
    if request.method == 'POST':
        email = request.form.get('email')
        conn = get_db()
        
        user = conn.execute(
            'SELECT * FROM users WHERE email = ?', (email,)
        ).fetchone()
        
        if user:
            if user['verified']:
                flash(_('Email is already verified.'), 'info')
                return redirect(url_for('login'))
            
            # Delete old tokens
            conn.execute(
                'DELETE FROM registration_tokens WHERE user_id = ?', (user['id'],)
            )
            
            # Generate new token
            token = generate_verification_token()
            conn.execute(
                'INSERT INTO registration_tokens (token, user_id) VALUES (?, ?)',
                (token, user['id'])
            )
            
            conn.commit()
            
            if send_verification_email(email, token):
                flash(_('Verification email sent! Please check your inbox.'), 'success')
            else:
                flash(_('Failed to send verification email. Please try again later.'), 'error')

            return redirect(url_for('login'))
        else:
            flash(_('Email not found.'), 'error')

    return render_template('resend_verification.html')

@app.route('/static/<path:filename>')
def serve_static(filename):
    return send_from_directory(app.static_folder, filename)

# API routes (protected)
@app.route('/api/tree', methods=['GET'])
def get_tree():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    conn = get_db()
    tree = conn.execute('SELECT * FROM tree ORDER BY tree_id, lft').fetchall()
    return jsonify([dict(node) for node in tree])

@app.route('/api/trees', methods=['GET'])
def get_trees():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    conn = get_db()
    trees = conn.execute('SELECT DISTINCT tree_id, name FROM tree WHERE level = 0 ORDER BY tree_id').fetchall()
    return jsonify([dict(tree) for tree in trees])

@app.route('/api/trees', methods=['POST'])
def create_tree():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    data = request.get_json()
    name = data.get('name', 'New Tree')
    try:
        conn = get_db()
        conn.execute('BEGIN TRANSACTION') 
        conn.execute('INSERT INTO add_root_operation (name) VALUES (?)', (name,))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400

@app.route('/api/nodes', methods=['POST'])
def add_node():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    data = request.get_json()
    conn = get_db()
    
    try:
        conn.execute('BEGIN TRANSACTION') 
        conn.execute('''
            INSERT INTO add_node_operation (target_node_id, name, position)
            VALUES (?, ?, ?)
        ''', (data['target_node_id'], data['name'], data['position']))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400

@app.route('/api/nodes/<int:node_id>', methods=['PUT'])
def rename_node(node_id):
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    data = request.get_json()
    conn = get_db()
    
    try:
        conn.execute('BEGIN TRANSACTION') 
        conn.execute('UPDATE tree SET name = ? WHERE id = ?', (data['name'], node_id))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400

@app.route('/api/nodes/move', methods=['POST'])
def move_node():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    data = request.get_json()
    conn = get_db()
    
    try:
        conn.execute('BEGIN TRANSACTION') 
        conn.execute('''
            INSERT INTO move_node_operation (node_id, target_node_id, position)
            VALUES (?, ?, ?)
        ''', (data['node_id'], data['target_node_id'], data['position']))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400

@app.route('/api/nodes/<int:node_id>', methods=['DELETE'])
def delete_node(node_id):
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    conn = get_db()
    
    try:
        conn.execute('BEGIN TRANSACTION') 
        conn.execute('INSERT INTO delete_node_operation (node_id) VALUES (?)', (node_id,))
        conn.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 400

@app.route('/api/tree/indented', methods=['GET'])
def get_indented_tree():
    if 'user_id' not in session:
        return jsonify({'error': 'Unauthorized'}), 401
    conn = get_db()
    tree = conn.execute('SELECT * FROM tree_indented ORDER BY tree_id, lft').fetchall()
    return jsonify([dict(node) for node in tree])

if __name__ == '__main__':
    app.run(debug=True)
