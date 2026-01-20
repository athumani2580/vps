#!/bin/bash

# =============================================
# SLOWDNS WEB PANEL INSTALLER WITH MARIADB
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Admin credentials
ADMIN_USER="admin"
ADMIN_PASS="Admin@1234"

# Server settings
SLOWDNS_PORT="5300"
WEB_DIR="/var/www/slowdns-panel"

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     SLOWDNS WEB PANEL INSTALLER         ║"
    echo "║          Version 3.0 - MariaDB          ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# Main installation
print_banner
check_root

print_info "Starting installation..."

# Update system
print_info "Updating system..."
apt update -y
apt upgrade -y

# Install MariaDB first
print_info "Installing MariaDB..."
apt install -y mariadb-server mariadb-client

# Start and enable MariaDB
systemctl start mariadb
systemctl enable mariadb

# Install other packages
print_info "Installing required packages..."
apt install -y php php-curl php-gd php-mbstring php-xml php-zip \
              php-mysql apache2 git curl wget unzip net-tools \
              python3 python3-pip

# Configure PHP
print_info "Configuring PHP..."
for php_ini in /etc/php/*/apache2/php.ini; do
    sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 100M/' $php_ini
    sed -i 's/^post_max_size =.*/post_max_size = 100M/' $php_ini
    sed -i 's/^memory_limit =.*/memory_limit = 512M/' $php_ini
    sed -i 's/^max_execution_time =.*/max_execution_time = 300/' $php_ini
    sed -i 's/^max_input_time =.*/max_input_time = 300/' $php_ini
    sed -i 's/^;date.timezone =.*/date.timezone = UTC/' $php_ini
done

# Configure MariaDB
print_info "Configuring MariaDB database..."

# Create database
mysql -e "CREATE DATABASE IF NOT EXISTS slowdns_panel;"
mysql -e "CREATE USER IF NOT EXISTS 'slowdns_admin'@'localhost' IDENTIFIED BY 'SlowDNS@2024';"
mysql -e "GRANT ALL PRIVILEGES ON slowdns_panel.* TO 'slowdns_admin'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Create tables
mysql slowdns_panel << 'EOF'
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role ENUM('admin', 'user') DEFAULT 'user',
    email VARCHAR(100),
    ip_limit INT DEFAULT 3,
    bandwidth_limit BIGINT DEFAULT 10737418240,
    bandwidth_used BIGINT DEFAULT 0,
    expiry_date DATE,
    status ENUM('active', 'inactive', 'expired') DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP NULL,
    last_ip VARCHAR(45),
    max_clients INT DEFAULT 5
);
EOF

# Insert admin user
ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")
mysql slowdns_panel << EOF
INSERT INTO users (username, password, role, email, ip_limit, bandwidth_limit, status, max_clients) 
VALUES ('$ADMIN_USER', '$ADMIN_HASH', 'admin', 'admin@example.com', 999, 1099511627776, 'active', 999)
ON DUPLICATE KEY UPDATE password='$ADMIN_HASH';
EOF

print_success "Database configured successfully"

# Create web directory
print_info "Creating web directory..."
rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
cd "$WEB_DIR"

# Create simple web panel
cat > index.php << 'EOF'
<?php
session_start();

// Database configuration
define('DB_HOST', 'localhost');
define('DB_NAME', 'slowdns_panel');
define('DB_USER', 'slowdns_admin');
define('DB_PASS', 'SlowDNS@2024');

// Connect to database
try {
    $pdo = new PDO(
        "mysql:host=" . DB_HOST . ";dbname=" . DB_NAME . ";charset=utf8mb4",
        DB_USER,
        DB_PASS,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException $e) {
    die("Database connection failed: " . $e->getMessage());
}

// Handle login
if ($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_POST['login'])) {
    $username = $_POST['username'];
    $password = $_POST['password'];
    
    $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ?");
    $stmt->execute([$username]);
    $user = $stmt->fetch();
    
    if ($user && password_verify($password, $user['password'])) {
        $_SESSION['user_id'] = $user['id'];
        $_SESSION['username'] = $user['username'];
        $_SESSION['role'] = $user['role'];
        header('Location: index.php');
        exit;
    } else {
        $error = "Invalid username or password";
    }
}

// Handle logout
if (isset($_GET['logout'])) {
    session_destroy();
    header('Location: index.php');
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SlowDNS Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background: #f8f9fa; }
        .login-card { max-width: 400px; margin: 100px auto; padding: 30px; }
        .dashboard-card { margin-bottom: 20px; }
    </style>
</head>
<body>
    <?php if (!isset($_SESSION['user_id'])): ?>
    <!-- Login Form -->
    <div class="container">
        <div class="login-card card shadow">
            <div class="card-body">
                <h3 class="text-center mb-4">SlowDNS Panel Login</h3>
                <?php if (isset($error)): ?>
                <div class="alert alert-danger"><?php echo $error; ?></div>
                <?php endif; ?>
                <form method="POST">
                    <div class="mb-3">
                        <label>Username</label>
                        <input type="text" name="username" class="form-control" required>
                    </div>
                    <div class="mb-3">
                        <label>Password</label>
                        <input type="password" name="password" class="form-control" required>
                    </div>
                    <button type="submit" name="login" class="btn btn-primary w-100">Login</button>
                </form>
            </div>
        </div>
    </div>
    <?php else: ?>
    <!-- Dashboard -->
    <nav class="navbar navbar-dark bg-dark">
        <div class="container-fluid">
            <a class="navbar-brand" href="#">SlowDNS Panel</a>
            <div class="navbar-nav">
                <span class="navbar-text me-3">Welcome, <?php echo $_SESSION['username']; ?></span>
                <a href="?logout" class="btn btn-outline-light btn-sm">Logout</a>
            </div>
        </div>
    </nav>
    
    <div class="container mt-4">
        <div class="row">
            <div class="col-md-3">
                <div class="card dashboard-card">
                    <div class="card-body">
                        <h5>Total Users</h5>
                        <?php
                        $stmt = $pdo->query("SELECT COUNT(*) as count FROM users");
                        $count = $stmt->fetch()['count'];
                        ?>
                        <h2><?php echo $count; ?></h2>
                    </div>
                </div>
            </div>
            <div class="col-md-9">
                <div class="card">
                    <div class="card-body">
                        <h4>User Management</h4>
                        <table class="table">
                            <thead>
                                <tr>
                                    <th>Username</th>
                                    <th>Role</th>
                                    <th>Status</th>
                                    <th>Created</th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php
                                $stmt = $pdo->query("SELECT * FROM users ORDER BY created_at DESC");
                                while ($user = $stmt->fetch()):
                                ?>
                                <tr>
                                    <td><?php echo htmlspecialchars($user['username']); ?></td>
                                    <td><span class="badge bg-<?php echo $user['role'] == 'admin' ? 'warning' : 'info'; ?>">
                                        <?php echo ucfirst($user['role']); ?>
                                    </span></td>
                                    <td><span class="badge bg-success">Active</span></td>
                                    <td><?php echo $user['created_at']; ?></td>
                                </tr>
                                <?php endwhile; ?>
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php endif; ?>
    
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# Set permissions
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"

# Configure Apache
print_info "Configuring Apache..."
cat > /etc/apache2/sites-available/slowdns-panel.conf << EOF
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot $WEB_DIR
    
    <Directory $WEB_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/slowdns-error.log
    CustomLog \${APACHE_LOG_DIR}/slowdns-access.log combined
</VirtualHost>
EOF

a2ensite slowdns-panel.conf
a2dissite 000-default.conf
a2enmod rewrite

# Restart Apache
systemctl restart apache2
systemctl enable apache2

# Configure firewall
print_info "Configuring firewall..."
ufw --force enable
ufw allow 80/tcp
ufw allow 22/tcp
ufw allow "$SLOWDNS_PORT"/udp

# Installation complete
print_success "Installation completed!"
echo ""
echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN}    SLOWDNS WEB PANEL INSTALLATION COMPLETE    ${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${GREEN}📊 PANEL URL:${NC}"
echo -e "   http://$(curl -s ifconfig.me)/"
echo ""
echo -e "${GREEN}🔐 ADMIN LOGIN:${NC}"
echo -e "   Username: ${RED}admin${NC}"
echo -e "   Password: ${RED}Admin@1234${NC}"
echo ""
echo -e "${YELLOW}⚠️  Change the admin password immediately!${NC}"
echo ""
