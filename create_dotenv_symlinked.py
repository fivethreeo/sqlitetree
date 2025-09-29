import secrets
import base64

# Generate a secure random byte string for the secret key
# A length of 32 bytes (256 bits) is generally recommended for strong keys
SECRET_KEY_BYTES = secrets.token_bytes(32)
JWT_SECRET_KEY_BYTES = secrets.token_bytes(32)

# Base64 encode the byte string
SECRET_KEY_BASE64 = base64.b64encode(SECRET_KEY_BYTES).decode('utf-8')
JWT_SECRET_KEY_BASE64 = base64.b64encode(JWT_SECRET_KEY_BYTES).decode('utf-8')

# symlink .env to home in linux and windows
import os
import platform
if platform.system() == 'Linux':
    home = os.path.expanduser("~")
    env_path = os.path.join(home, '.env.tinyicms')
    if not os.path.exists(env_path):
        os.symlink(os.path.abspath('.env'), env_path)
elif platform.system() == 'Windows':
    home = os.path.expanduser("~")
    env_path = os.path.join(home, '.env.tinyicms')
    if not os.path.exists(env_path):
        os.symlink(os.path.abspath('.env'), env_path)

with open('.env', 'a') as env_file:
    env_file.write(f'SECRET_KEY={SECRET_KEY_BASE64}\n')
    env_file.write(f'JWT_SECRET_KEY={JWT_SECRET_KEY_BASE64}\n')

