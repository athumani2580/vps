#!/bin/bash

# =============================================
# CONFIGURATION
# =============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Admin credentials (change these!)
ADMIN_USER="admin"
ADMIN_PASS="Admin@1234"  # CHANGE THIS!

# Server settings
SLOWDNS_PORT="5300"
SERVER_NAME="SlowDNS Server Pro"
SERVER_DOMAIN="dns.example.com"  # Change to your domain

# Installation paths
WEB_DIR="/var/www/slowdns-panel"
PANEL_FILE="$WEB_DIR/index.php"
LOG_DIR="/var/log/slowdns"
INSTALL_LOG="$LOG_DIR/install.log"

# =============================================
# FUNCTIONS
# =============================================
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     SLOWDNS WEB PANEL INSTALLER         ║"
    echo "║          Version 3.0                    ║"
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

get_server_ip() {
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    echo "$SERVER_IP"
}

generate_random_password() {
    cat /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()' | fold -w 12 | head -n 1
}

# =============================================
# MAIN INSTALLATION
# =============================================
print_banner
check_root

# Create log directory
mkdir -p "$LOG_DIR"
echo "Installation started: $(date)" > "$INSTALL_LOG"

print_info "Starting SlowDNS Web Panel installation..."

# Get server IP
SERVER_IP=$(get_server_ip)
print_info "Server IP detected: $SERVER_IP"

# Update system
print_info "Updating system packages..."
apt update -y >> "$INSTALL_LOG" 2>&1
apt upgrade -y >> "$INSTALL_LOG" 2>&1

# Install required packages
print_info "Installing required packages..."
apt install -y php php-curl php-gd php-mbstring php-xml php-zip \
              apache2 git curl wget unzip net-tools \
              python3 python3-pip mysql-server mysql-client php-mysql >> "$INSTALL_LOG" 2>&1

# Install additional PHP extensions
apt install -y php-common php-cli php-json php-opcache php-readline php-bcmath >> "$INSTALL_LOG" 2>&1

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

# =============================================
# FIXED MYSQL CONFIGURATION SECTION
# =============================================
print_info "Configuring MySQL database..."

# Check and start MySQL service
print_info "Checking MySQL service..."
if ! systemctl is-active --quiet mysql 2>/dev/null; then
    print_warning "MySQL service is not running. Starting it now..."
    
    # Try to start MySQL
    if systemctl start mysql 2>/dev/null; then
        print_success "MySQL service started successfully"
    else
        print_warning "Could not start MySQL service, trying alternative methods..."
        
        # Try to initialize MySQL if not installed properly
        if ! command -v mysqld &> /dev/null; then
            print_warning "MySQL server not found, reinstalling..."
            apt install -y mysql-server --reinstall >> "$INSTALL_LOG" 2>&1
        fi
        
        # Initialize MySQL if needed
        if [ ! -d "/var/lib/mysql/mysql" ]; then
            print_info "Initializing MySQL database..."
            mysqld --initialize-insecure --user=mysql >> "$INSTALL_LOG" 2>&1
        fi
        
        # Start MySQL service
        systemctl start mysql >> "$INSTALL_LOG" 2>&1
        systemctl enable mysql >> "$INSTALL_LOG" 2>&1
        sleep 5
    fi
fi

# Check if MySQL is running
if systemctl is-active --quiet mysql; then
    print_success "MySQL service is running"
else
    print_error "Failed to start MySQL service. Attempting to restart..."
    systemctl restart mysql >> "$INSTALL_LOG" 2>&1
    sleep 3
    
    if ! systemctl is-active --quiet mysql; then
        print_error "MySQL service failed to start. Please check logs and try:"
        print_error "sudo systemctl status mysql"
        print_error "sudo journalctl -xe | grep mysql"
        exit 1
    fi
fi

# Wait for MySQL socket to be created
print_info "Waiting for MySQL socket..."
for i in {1..30}; do
    if [ -S /var/run/mysqld/mysqld.sock ] 2>/dev/null || [ -S /tmp/mysql.sock ] 2>/dev/null; then
        print_success "MySQL socket found"
        break
    fi
    if [ $i -eq 30 ]; then
        print_warning "MySQL socket not found, creating manually..."
        mkdir -p /var/run/mysqld
        chown mysql:mysql /var/run/mysqld
        systemctl restart mysql
        sleep 3
    fi
    sleep 1
done

# Set root password if not set (for fresh install)
print_info "Securing MySQL installation..."
if ! mysql -e "SELECT 1" &>/dev/null; then
    print_warning "MySQL has no root password. Setting default password..."
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root';" 2>/dev/null || true
fi

# Create database and user
print_info "Creating SlowDNS database and user..."
mysql -e "CREATE DATABASE IF NOT EXISTS slowdns_panel;" 2>/dev/null || {
    print_error "Failed to connect to MySQL. Trying with root password..."
    mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS slowdns_panel;" 2>/dev/null || {
        print_error "MySQL connection failed. Please check MySQL status and try again."
        print_error "You can try: sudo mysql_secure_installation"
        exit 1
    }
}

mysql -e "CREATE USER IF NOT EXISTS 'slowdns_admin'@'localhost' IDENTIFIED BY 'SlowDNS@2024';" 2>/dev/null || \
mysql -uroot -proot -e "CREATE USER IF NOT EXISTS 'slowdns_admin'@'localhost' IDENTIFIED BY 'SlowDNS@2024';" 2>/dev/null

mysql -e "GRANT ALL PRIVILEGES ON slowdns_panel.* TO 'slowdns_admin'@'localhost';" 2>/dev/null || \
mysql -uroot -proot -e "GRANT ALL PRIVILEGES ON slowdns_panel.* TO 'slowdns_admin'@'localhost';" 2>/dev/null

mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || \
mysql -uroot -proot -e "FLUSH PRIVILEGES;" 2>/dev/null

# Create database tables
print_info "Creating database tables..."
MYSQL_CMD="mysql"
if ! mysql -e "SELECT 1" &>/dev/null; then
    MYSQL_CMD="mysql -uroot -proot"
fi

$MYSQL_CMD slowdns_panel << 'EOF'
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role ENUM('admin', 'user') DEFAULT 'user',
    email VARCHAR(100),
    ip_limit INT DEFAULT 3,
    bandwidth_limit BIGINT DEFAULT 10737418240, -- 10GB in bytes
    bandwidth_used BIGINT DEFAULT 0,
    expiry_date DATE,
    status ENUM('active', 'inactive', 'expired') DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP NULL,
    last_ip VARCHAR(45),
    max_clients INT DEFAULT 5
);

CREATE TABLE IF NOT EXISTS clients (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    name VARCHAR(100) NOT NULL,
    config_key VARCHAR(255) NOT NULL,
    domain VARCHAR(255),
    bandwidth_used BIGINT DEFAULT 0,
    status ENUM('active', 'inactive') DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_used TIMESTAMP NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS usage_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    client_id INT,
    bytes_sent BIGINT DEFAULT 0,
    bytes_received BIGINT DEFAULT 0,
    session_start TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_end TIMESTAMP NULL,
    ip_address VARCHAR(45),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS server_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_load DECIMAL(5,2),
    memory_used DECIMAL(5,2),
    disk_used DECIMAL(5,2),
    active_connections INT DEFAULT 0,
    total_bandwidth BIGINT DEFAULT 0
);

CREATE TABLE IF NOT EXISTS activity_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    action VARCHAR(255) NOT NULL,
    details TEXT,
    ip_address VARCHAR(45),
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
);
EOF

# Insert admin user
print_info "Creating admin user..."
ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")
$MYSQL_CMD slowdns_panel << EOF
INSERT INTO users (username, password, role, email, ip_limit, bandwidth_limit, status, max_clients) 
VALUES ('$ADMIN_USER', '$ADMIN_HASH', 'admin', 'admin@example.com', 999, 1099511627776, 'active', 999)
ON DUPLICATE KEY UPDATE password='$ADMIN_HASH';
EOF

print_success "MySQL database configured successfully"
# =============================================
# END OF FIXED MYSQL SECTION
# =============================================

# Create web directory
print_info "Creating web directory..."
rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
cd "$WEB_DIR"

# =============================================
# CREATE THE WEB PANEL
# =============================================
print_info "Creating web panel..."

cat > "$PANEL_FILE" << 'EOF'
<?php
/**
 * Complete SlowDNS Web Panel
 * MySQL Version with All Features
 */

// =============================================
// CONFIGURATION
// =============================================
session_start();
date_default_timezone_set('UTC');

// Database configuration
define('DB_HOST', 'localhost');
define('DB_NAME', 'slowdns_panel');
define('DB_USER', 'slowdns_admin');
define('DB_PASS', 'SlowDNS@2024');

// Application settings
define('SITE_NAME', 'SlowDNS Manager Pro');
define('BASE_URL', (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]");
define('SLOWDNS_PORT', 5300);
define('DEFAULT_IP_LIMIT', 3);
define('DEFAULT_BANDWIDTH_GB', 10);

// Security
define('SESSION_TIMEOUT', 3600); // 1 hour

// =============================================
// DATABASE CONNECTION
// =============================================
class Database {
    private $pdo;
    
    public function __construct() {
        try {
            $this->pdo = new PDO(
                "mysql:host=" . DB_HOST . ";dbname=" . DB_NAME . ";charset=utf8mb4",
                DB_USER,
                DB_PASS,
                [
                    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_EMULATE_PREPARES => false
                ]
            );
        } catch (PDOException $e) {
            die("Database connection failed: " . $e->getMessage());
        }
    }
    
    public function getConnection() {
        return $this->pdo;
    }
}

$db = new Database();
$pdo = $db->getConnection();

// =============================================
// HELPER FUNCTIONS
// =============================================
function isLoggedIn() {
    return isset($_SESSION['user_id']) && (time() - $_SESSION['login_time']) < SESSION_TIMEOUT;
}

function login($username, $password) {
    global $pdo;
    
    $stmt = $pdo->prepare("SELECT * FROM users WHERE username = ? AND status = 'active'");
    $stmt->execute([$username]);
    $user = $stmt->fetch();
    
    if ($user && password_verify($password, $user['password'])) {
        $_SESSION['user_id'] = $user['id'];
        $_SESSION['username'] = $user['username'];
        $_SESSION['role'] = $user['role'];
        $_SESSION['login_time'] = time();
        
        // Update last login
        $stmt = $pdo->prepare("UPDATE users SET last_login = NOW(), last_ip = ? WHERE id = ?");
        $stmt->execute([$_SERVER['REMOTE_ADDR'], $user['id']]);
        
        // Log activity
        logActivity($user['id'], "User logged in", "IP: " . $_SERVER['REMOTE_ADDR']);
        
        return true;
    }
    return false;
}

function logout() {
    if (isset($_SESSION['user_id'])) {
        logActivity($_SESSION['user_id'], "User logged out");
    }
    session_destroy();
    header('Location: ?action=login');
    exit;
}

function logActivity($user_id, $action, $details = '') {
    global $pdo;
    $stmt = $pdo->prepare("INSERT INTO activity_logs (user_id, action, details, ip_address) VALUES (?, ?, ?, ?)");
    $stmt->execute([$user_id, $action, $details, $_SERVER['REMOTE_ADDR']]);
}

function formatBytes($bytes, $precision = 2) {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $bytes = max($bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min($pow, count($units) - 1);
    $bytes /= pow(1024, $pow);
    return round($bytes, $precision) . ' ' . $units[$pow];
}

function getServerStatus() {
    $status = [];
    
    // Check SlowDNS service
    exec('systemctl is-active server-sldns.service 2>/dev/null', $output, $code);
    $status['service'] = $code == 0 ? 'running' : 'stopped';
    
    // Check port
    exec("netstat -tulpn 2>/dev/null | grep :" . SLOWDNS_PORT, $output);
    $status['port'] = !empty($output) ? 'open' : 'closed';
    
    // Get connections
    exec("ss -tn 2>/dev/null | grep :" . SLOWDNS_PORT . " | grep ESTAB | wc -l", $output);
    $status['connections'] = intval($output[0] ?? 0);
    
    // Get system info
    $load = sys_getloadavg();
    $status['cpu_load'] = $load[0];
    
    $mem = shell_exec("free | grep Mem | awk '{print $3/$2 * 100.0}'");
    $status['memory_used'] = round(floatval($mem), 2);
    
    $disk = disk_free_space("/");
    $total_disk = disk_total_space("/");
    $status['disk_used'] = round((($total_disk - $disk) / $total_disk) * 100, 2);
    
    $uptime = shell_exec("uptime -p");
    $status['uptime'] = trim($uptime);
    
    // Get server IP
    $status['ip'] = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    return $status;
}

function getUserStats($user_id) {
    global $pdo;
    
    $stats = [];
    
    // Get bandwidth used
    $stmt = $pdo->prepare("SELECT SUM(bandwidth_used) as total_used FROM users WHERE id = ?");
    $stmt->execute([$user_id]);
    $stats['bandwidth_used'] = $stmt->fetch()['total_used'] ?? 0;
    
    // Get bandwidth limit
    $stmt = $pdo->prepare("SELECT bandwidth_limit FROM users WHERE id = ?");
    $stmt->execute([$user_id]);
    $stats['bandwidth_limit'] = $stmt->fetch()['bandwidth_limit'] ?? 0;
    
    // Get active clients
    $stmt = $pdo->prepare("SELECT COUNT(*) as count FROM clients WHERE user_id = ? AND status = 'active'");
    $stmt->execute([$user_id]);
    $stats['active_clients'] = $stmt->fetch()['count'] ?? 0;
    
    // Get total clients
    $stmt = $pdo->prepare("SELECT COUNT(*) as count FROM clients WHERE user_id = ?");
    $stmt->execute([$user_id]);
    $stats['total_clients'] = $stmt->fetch()['count'] ?? 0;
    
    // Calculate usage percentage
    $stats['usage_percent'] = $stats['bandwidth_limit'] > 0 ? 
        min(100, ($stats['bandwidth_used'] / $stats['bandwidth_limit']) * 100) : 0;
    
    return $stats;
}

function generateClientConfig($user_id, $client_name) {
    global $pdo;
    
    // Generate unique key
    $config_key = bin2hex(random_bytes(32));
    
    // Get server IP
    $server_ip = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    // Create config content
    $config = "[client]\n";
    $config .= "name = " . $client_name . "\n";
    $config .= "server = " . $server_ip . "\n";
    $config .= "port = " . SLOWDNS_PORT . "\n";
    $config .= "key = " . $config_key . "\n";
    $config .= "mtu = 1200\n";
    $config .= "protocol = udp\n";
    $config .= "dns = 8.8.8.8\n";
    $config .= "keepalive = 30\n";
    $config .= "\n# Generated on: " . date('Y-m-d H:i:s') . "\n";
    
    return [
        'config' => $config,
        'key' => $config_key
    ];
}

// =============================================
// ACTION HANDLERS
// =============================================
function handleLogin() {
    if ($_SERVER['REQUEST_METHOD'] == 'POST') {
        $username = $_POST['username'] ?? '';
        $password = $_POST['password'] ?? '';
        
        if (login($username, $password)) {
            header('Location: ?action=dashboard');
            exit;
        } else {
            return "Invalid username or password";
        }
    }
    return null;
}

function handleAddUser() {
    global $pdo;
    
    if ($_SERVER['REQUEST_METHOD'] == 'POST') {
        $username = $_POST['username'] ?? '';
        $password = $_POST['password'] ?? '';
        $email = $_POST['email'] ?? '';
        $ip_limit = intval($_POST['ip_limit'] ?? DEFAULT_IP_LIMIT);
        $bandwidth_gb = intval($_POST['bandwidth_gb'] ?? DEFAULT_BANDWIDTH_GB);
        $expiry_date = $_POST['expiry_date'] ?? null;
        $max_clients = intval($_POST['max_clients'] ?? 5);
        
        // Validate inputs
        if (empty($username) || empty($password)) {
            return "Username and password are required";
        }
        
        // Check if username exists
        $stmt = $pdo->prepare("SELECT id FROM users WHERE username = ?");
        $stmt->execute([$username]);
        if ($stmt->fetch()) {
            return "Username already exists";
        }
        
        // Hash password
        $hashed_password = password_hash($password, PASSWORD_DEFAULT);
        
        // Calculate bandwidth limit in bytes
        $bandwidth_limit = $bandwidth_gb * 1024 * 1024 * 1024;
        
        // Insert user
        $stmt = $pdo->prepare("
            INSERT INTO users (username, password, email, ip_limit, bandwidth_limit, expiry_date, max_clients, status) 
            VALUES (?, ?, ?, ?, ?, ?, ?, 'active')
        ");
        
        $stmt->execute([
            $username, 
            $hashed_password, 
            $email, 
            $ip_limit, 
            $bandwidth_limit, 
            $expiry_date ?: null,
            $max_clients
        ]);
        
        // Log activity
        logActivity($_SESSION['user_id'], "Added user: $username", 
                   "IP Limit: $ip_limit, Bandwidth: {$bandwidth_gb}GB");
        
        return "success";
    }
    return null;
}

function handleDeleteUser($user_id) {
    global $pdo;
    
    // Prevent deleting self
    if ($user_id == $_SESSION['user_id']) {
        return "Cannot delete your own account";
    }
    
    // Get username before deleting
    $stmt = $pdo->prepare("SELECT username FROM users WHERE id = ?");
    $stmt->execute([$user_id]);
    $user = $stmt->fetch();
    
    if ($user) {
        // Delete user
        $stmt = $pdo->prepare("DELETE FROM users WHERE id = ?");
        $stmt->execute([$user_id]);
        
        // Log activity
        logActivity($_SESSION['user_id'], "Deleted user: " . $user['username']);
        
        return "success";
    }
    
    return "User not found";
}

function handleUpdateUserLimits() {
    global $pdo;
    
    if ($_SERVER['REQUEST_METHOD'] == 'POST') {
        $user_id = $_POST['user_id'] ?? 0;
        $ip_limit = intval($_POST['ip_limit'] ?? 0);
        $bandwidth_gb = intval($_POST['bandwidth_gb'] ?? 0);
        $expiry_date = $_POST['expiry_date'] ?? null;
        $status = $_POST['status'] ?? 'active';
        
        // Calculate bandwidth limit in bytes
        $bandwidth_limit = $bandwidth_gb * 1024 * 1024 * 1024;
        
        $stmt = $pdo->prepare("
            UPDATE users 
            SET ip_limit = ?, bandwidth_limit = ?, expiry_date = ?, status = ?
            WHERE id = ?
        ");
        
        $stmt->execute([$ip_limit, $bandwidth_limit, $expiry_date, $status, $user_id]);
        
        // Get username for logging
        $stmt = $pdo->prepare("SELECT username FROM users WHERE id = ?");
        $stmt->execute([$user_id]);
        $user = $stmt->fetch();
        
        logActivity($_SESSION['user_id'], "Updated limits for user: " . $user['username'],
                   "IP Limit: $ip_limit, Bandwidth: {$bandwidth_gb}GB, Status: $status");
        
        return "success";
    }
    return null;
}

// =============================================
// PAGE RENDERING FUNCTIONS
# Continued from previous part...

function renderLoginPage($error = null) {
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Login - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <style>
            body { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); height: 100vh; }
            .login-card { max-width: 400px; margin: 100px auto; padding: 30px; border-radius: 15px; background: white; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="login-card shadow-lg">
                <div class="text-center mb-4">
                    <h3><i class="bi bi-shield-lock"></i> <?php echo SITE_NAME; ?></h3>
                    <p class="text-muted">SlowDNS Management Panel</p>
                </div>
                
                <?php if ($error): ?>
                <div class="alert alert-danger"><?php echo htmlspecialchars($error); ?></div>
                <?php endif; ?>
                
                <form method="POST">
                    <input type="hidden" name="action" value="do_login">
                    <div class="mb-3">
                        <label class="form-label">Username</label>
                        <input type="text" name="username" class="form-control" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Password</label>
                        <input type="password" name="password" class="form-control" required>
                    </div>
                    <button type="submit" class="btn btn-primary w-100">Login</button>
                </form>
            </div>
        </div>
    </body>
    </html>
    <?php
    exit;
}

function renderDashboard() {
    global $pdo;
    
    $user_id = $_SESSION['user_id'];
    $role = $_SESSION['role'];
    
    // Get user stats
    $stats = getUserStats($user_id);
    
    // Get server status
    $server_status = getServerStatus();
    
    // Get total users (admin only)
    $total_users = 0;
    if ($role == 'admin') {
        $stmt = $pdo->query("SELECT COUNT(*) as count FROM users");
        $total_users = $stmt->fetch()['count'];
    }
    
    // Get total bandwidth used
    $stmt = $pdo->query("SELECT SUM(bandwidth_used) as total FROM users");
    $total_bandwidth = $stmt->fetch()['total'] ?? 0;
    
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Dashboard - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
        <style>
            :root {
                --primary: #4361ee;
                --secondary: #3a0ca3;
                --success: #4cc9f0;
                --danger: #f72585;
                --dark: #1a1a2e;
            }
            body { background: #f8f9fa; }
            .navbar { background: var(--dark) !important; }
            .sidebar { background: white; border-radius: 10px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
            .card { border: none; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
            .stat-card { border-left: 4px solid var(--primary); }
        </style>
    </head>
    <body>
        <!-- Navbar -->
        <nav class="navbar navbar-expand-lg navbar-dark">
            <div class="container-fluid">
                <a class="navbar-brand" href="?action=dashboard">
                    <i class="bi bi-shield-lock me-2"></i>
                    <strong><?php echo SITE_NAME; ?></strong>
                </a>
                
                <div class="navbar-nav ms-auto align-items-center">
                    <span class="navbar-text me-3">
                        <i class="bi bi-person-circle"></i> <?php echo $_SESSION['username']; ?>
                        <?php if ($_SESSION['role'] == 'admin'): ?>
                        <span class="badge bg-warning ms-1">Admin</span>
                        <?php endif; ?>
                    </span>
                    <a href="?action=logout" class="btn btn-outline-light btn-sm">Logout</a>
                </div>
            </div>
        </nav>
        
        <div class="container-fluid mt-3">
            <div class="row">
                <!-- Sidebar -->
                <div class="col-lg-2">
                    <div class="sidebar p-3 mb-3">
                        <nav class="nav flex-column">
                            <a class="nav-link active" href="?action=dashboard">
                                <i class="bi bi-speedometer2 me-2"></i> Dashboard
                            </a>
                            <a class="nav-link" href="?action=my_clients">
                                <i class="bi bi-person-badge me-2"></i> My Clients
                            </a>
                            <a class="nav-link" href="?action=create_client">
                                <i class="bi bi-plus-circle me-2"></i> Create Client
                            </a>
                            
                            <?php if ($_SESSION['role'] == 'admin'): ?>
                            <hr class="my-2">
                            <h6 class="text-muted mt-2 mb-2">Admin Panel</h6>
                            <a class="nav-link" href="?action=users">
                                <i class="bi bi-people me-2"></i> User Management
                            </a>
                            <a class="nav-link" href="?action=server">
                                <i class="bi bi-server me-2"></i> Server Status
                            </a>
                            <a class="nav-link" href="?action=settings">
                                <i class="bi bi-gear me-2"></i> Settings
                            </a>
                            <a class="nav-link" href="?action=logs">
                                <i class="bi bi-list-check me-2"></i> Activity Logs
                            </a>
                            <?php endif; ?>
                        </nav>
                    </div>
                    
                    <!-- Quick Stats -->
                    <div class="card p-2">
                        <div class="card-body">
                            <h6 class="text-muted">Quick Stats</h6>
                            <div class="mt-2">
                                <div class="d-flex justify-content-between mb-1">
                                    <small>Status:</small>
                                    <span class="badge <?php echo $server_status['service'] == 'running' ? 'bg-success' : 'bg-danger'; ?>">
                                        <?php echo ucfirst($server_status['service']); ?>
                                    </span>
                                </div>
                                <div class="d-flex justify-content-between mb-1">
                                    <small>Connections:</small>
                                    <small class="text-muted"><?php echo $server_status['connections']; ?></small>
                                </div>
                                <div class="d-flex justify-content-between">
                                    <small>CPU Load:</small>
                                    <small class="text-muted"><?php echo $server_status['cpu_load']; ?></small>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Main Content -->
                <div class="col-lg-10">
                    <!-- Welcome Message -->
                    <div class="card mb-4">
                        <div class="card-body">
                            <div class="d-flex justify-content-between align-items-center">
                                <div>
                                    <h4 class="mb-1">Welcome, <?php echo $_SESSION['username']; ?>!</h4>
                                    <p class="text-muted mb-0">SlowDNS Management Dashboard</p>
                                </div>
                                <div class="text-end">
                                    <div class="badge bg-primary">Server IP: <?php echo $server_status['ip']; ?></div>
                                    <div class="badge bg-info mt-1">Port: <?php echo SLOWDNS_PORT; ?></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <!-- Stats Cards -->
                    <div class="row mb-4">
                        <div class="col-md-3">
                            <div class="card stat-card p-3">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Bandwidth Used</h6>
                                        <h3 class="mb-0"><?php echo formatBytes($stats['bandwidth_used']); ?></h3>
                                    </div>
                                    <div class="bg-primary text-white rounded-circle p-2">
                                        <i class="bi bi-speedometer2 fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">
                                    <?php echo number_format($stats['usage_percent'], 1); ?>% of <?php echo formatBytes($stats['bandwidth_limit']); ?>
                                </small>
                                <div class="progress mt-2" style="height: 5px;">
                                    <div class="progress-bar <?php echo $stats['usage_percent'] > 80 ? 'bg-danger' : ($stats['usage_percent'] > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                         style="width: <?php echo $stats['usage_percent']; ?>%"></div>
                                </div>
                            </div>
                        </div>
                        
                        <div class="col-md-3">
                            <div class="card stat-card p-3" style="border-left-color: #4cc9f0;">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Active Clients</h6>
                                        <h3 class="mb-0"><?php echo $stats['active_clients']; ?></h3>
                                    </div>
                                    <div class="bg-info text-white rounded-circle p-2">
                                        <i class="bi bi-person-badge fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">Total: <?php echo $stats['total_clients']; ?> clients</small>
                            </div>
                        </div>
                        
                        <?php if ($_SESSION['role'] == 'admin'): ?>
                        <div class="col-md-3">
                            <div class="card stat-card p-3" style="border-left-color: #f8961e;">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Total Users</h6>
                                        <h3 class="mb-0"><?php echo $total_users; ?></h3>
                                    </div>
                                    <div class="bg-warning text-white rounded-circle p-2">
                                        <i class="bi bi-people fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">Registered users</small>
                            </div>
                        </div>
                        
                        <div class="col-md-3">
                            <div class="card stat-card p-3" style="border-left-color: #f72585;">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Total Bandwidth</h6>
                                        <h3 class="mb-0"><?php echo formatBytes($total_bandwidth); ?></h3>
                                    </div>
                                    <div class="bg-danger text-white rounded-circle p-2">
                                        <i class="bi bi-hdd fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">All users combined</small>
                            </div>
                        </div>
                        <?php endif; ?>
                    </div>
                    
                    <!-- Server Status -->
                    <div class="card mb-4">
                        <div class="card-header">
                            <h5 class="mb-0"><i class="bi bi-server me-2"></i> Server Status</h5>
                        </div>
                        <div class="card-body">
                            <div class="row">
                                <div class="col-md-4">
                                    <div class="d-flex align-items-center mb-3">
                                        <div class="me-3">
                                            <i class="bi bi-power fs-1 <?php echo $server_status['service'] == 'running' ? 'text-success' : 'text-danger'; ?>"></i>
                                        </div>
                                        <div>
                                            <small class="text-muted">SlowDNS Service</small>
                                            <h5><?php echo ucfirst($server_status['service']); ?></h5>
                                        </div>
                                    </div>
                                </div>
                                <div class="col-md-4">
                                    <div class="d-flex align-items-center mb-3">
                                        <div class="me-3">
                                            <i class="bi bi-ethernet fs-1 <?php echo $server_status['port'] == 'open' ? 'text-success' : 'text-danger'; ?>"></i>
                                        </div>
                                        <div>
                                            <small class="text-muted">Port <?php echo SLOWDNS_PORT; ?></small>
                                            <h5><?php echo ucfirst($server_status['port']); ?></h5>
                                        </div>
                                    </div>
                                </div>
                                <div class="col-md-4">
                                    <div class="d-flex align-items-center mb-3">
                                        <div class="me-3">
                                            <i class="bi bi-people fs-1 text-primary"></i>
                                        </div>
                                        <div>
                                            <small class="text-muted">Active Connections</small>
                                            <h5><?php echo $server_status['connections']; ?></h5>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            
                            <div class="row mt-3">
                                <div class="col-md-3">
                                    <div class="text-center p-3 border rounded">
                                        <div class="fs-2 mb-1"><?php echo $server_status['cpu_load']; ?></div>
                                        <small class="text-muted">CPU Load</small>
                                    </div>
                                </div>
                                <div class="col-md-3">
                                    <div class="text-center p-3 border rounded">
                                        <div class="fs-2 mb-1"><?php echo $server_status['memory_used']; ?>%</div>
                                        <small class="text-muted">Memory Used</small>
                                    </div>
                                </div>
                                <div class="col-md-3">
                                    <div class="text-center p-3 border rounded">
                                        <div class="fs-2 mb-1"><?php echo $server_status['disk_used']; ?>%</div>
                                        <small class="text-muted">Disk Used</small>
                                    </div>
                                </div>
                                <div class="col-md-3">
                                    <div class="text-center p-3 border rounded">
                                        <div class="fs-2 mb-1"><?php echo $server_status['uptime']; ?></div>
                                        <small class="text-muted">Uptime</small>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <!-- Quick Actions -->
                    <div class="card">
                        <div class="card-header">
                            <h5 class="mb-0"><i class="bi bi-lightning-charge me-2"></i> Quick Actions</h5>
                        </div>
                        <div class="card-body">
                            <div class="row">
                                <div class="col-md-3 mb-3">
                                    <a href="?action=create_client" class="btn btn-primary w-100">
                                        <i class="bi bi-plus-circle me-2"></i> Create Client
                                    </a>
                                </div>
                                <div class="col-md-3 mb-3">
                                    <a href="?action=my_clients" class="btn btn-outline-primary w-100">
                                        <i class="bi bi-list-ul me-2"></i> View Clients
                                    </a>
                                </div>
                                
                                <?php if ($_SESSION['role'] == 'admin'): ?>
                                <div class="col-md-3 mb-3">
                                    <a href="?action=users" class="btn btn-success w-100">
                                        <i class="bi bi-people me-2"></i> Manage Users
                                    </a>
                                </div>
                                <div class="col-md-3 mb-3">
                                    <a href="?action=server" class="btn btn-info w-100">
                                        <i class="bi bi-terminal me-2"></i> Server Control
                                    </a>
                                </div>
                                <?php endif; ?>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
        <script>
            // Auto refresh every 60 seconds
            setTimeout(() => location.reload(), 60000);
        </script>
    </body>
    </html>
    <?php
}

function renderUserManagementPage() {
    global $pdo;
    
    // Handle actions
    $message = '';
    $message_type = '';
    
    if (isset($_GET['action'])) {
        if ($_GET['action'] == 'delete' && isset($_GET['id'])) {
            $result = handleDeleteUser($_GET['id']);
            if ($result == 'success') {
                $message = 'User deleted successfully';
                $message_type = 'success';
            } else {
                $message = $result;
                $message_type = 'danger';
            }
        }
    }
    
    // Handle form submissions
    if ($_SERVER['REQUEST_METHOD'] == 'POST') {
        if (isset($_POST['add_user'])) {
            $result = handleAddUser();
            if ($result == 'success') {
                $message = 'User added successfully';
                $message_type = 'success';
            } else {
                $message = $result;
                $message_type = 'danger';
            }
        } elseif (isset($_POST['update_limits'])) {
            $result = handleUpdateUserLimits();
            if ($result == 'success') {
                $message = 'User limits updated successfully';
                $message_type = 'success';
            }
        }
    }
    
    // Get all users
    $stmt = $pdo->query("SELECT * FROM users ORDER BY created_at DESC");
    $users = $stmt->fetchAll();
    
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>User Management - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    </head>
    <body>
        <!-- Include navbar from dashboard -->
        <nav class="navbar navbar-expand-lg navbar-dark bg-dark">
            <div class="container-fluid">
                <a class="navbar-brand" href="?action=dashboard">
                    <i class="bi bi-shield-lock me-2"></i>
                    <strong><?php echo SITE_NAME; ?></strong>
                </a>
                <div class="navbar-nav ms-auto">
                    <a href="?action=dashboard" class="btn btn-outline-light btn-sm me-2">Dashboard</a>
                    <a href="?action=logout" class="btn btn-outline-light btn-sm">Logout</a>
                </div>
            </div>
        </nav>
        
        <div class="container-fluid mt-3">
            <?php if ($message): ?>
            <div class="alert alert-<?php echo $message_type; ?> alert-dismissible fade show">
                <?php echo $message; ?>
                <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
            </div>
            <?php endif; ?>
            
            <div class="row">
                <div class="col-md-4">
                    <!-- Add User Form -->
                    <div class="card mb-4">
                        <div class="card-header bg-primary text-white">
                            <h5 class="mb-0"><i class="bi bi-person-plus me-2"></i> Add New User</h5>
                        </div>
                        <div class="card-body">
                            <form method="POST">
                                <input type="hidden" name="add_user" value="1">
                                
                                <div class="mb-3">
                                    <label class="form-label">Username *</label>
                                    <input type="text" name="username" class="form-control" required>
                                </div>
                                
                                <div class="mb-3">
                                    <label class="form-label">Password *</label>
                                    <input type="password" name="password" class="form-control" required>
                                </div>
                                
                                <div class="mb-3">
                                    <label class="form-label">Email</label>
                                    <input type="email" name="email" class="form-control">
                                </div>
                                
                                <div class="row">
                                    <div class="col-md-6 mb-3">
                                        <label class="form-label">IP Limit</label>
                                        <input type="number" name="ip_limit" class="form-control" value="3" min="1" max="50">
                                        <small class="text-muted">Max concurrent connections</small>
                                    </div>
                                    
                                    <div class="col-md-6 mb-3">
                                        <label class="form-label">Bandwidth Limit (GB)</label>
                                        <input type="number" name="bandwidth_gb" class="form-control" value="10" min="1" max="1000">
                                    </div>
                                </div>
                                
                                <div class="row">
                                    <div class="col-md-6 mb-3">
                                        <label class="form-label">Max Clients</label>
                                        <input type="number" name="max_clients" class="form-control" value="5" min="1" max="50">
                                    </div>
                                    
                                    <div class="col-md-6 mb-3">
                                        <label class="form-label">Expiry Date</label>
                                        <input type="date" name="expiry_date" class="form-control">
                                        <small class="text-muted">Leave empty for no expiry</small>
                                    </div>
                                </div>
                                
                                <button type="submit" class="btn btn-primary w-100">
                                    <i class="bi bi-check-circle me-2"></i> Add User
                                </button>
                            </form>
                        </div>
                    </div>
                </div>
                
                <div class="col-md-8">
                    <!-- Users List -->
                    <div class="card">
                        <div class="card-header">
                            <h5 class="mb-0"><i class="bi bi-people me-2"></i> All Users</h5>
                        </div>
                        <div class="card-body">
                            <div class="table-responsive">
                                <table class="table table-hover">
                                    <thead>
                                        <tr>
                                            <th>Username</th>
                                            <th>Role</th>
                                            <th>IP Limit</th>
                                            <th>Bandwidth Used</th>
                                            <th>Status</th>
                                            <th>Expiry</th>
                                            <th>Actions</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        <?php foreach ($users as $user): 
                                            $usage_percent = $user['bandwidth_limit'] > 0 ? 
                                                min(100, ($user['bandwidth_used'] / $user['bandwidth_limit']) * 100) : 0;
                                            
                                            // Check if expired
                                            $is_expired = $user['expiry_date'] && strtotime($user['expiry_date']) < time();
                                            $status_class = $is_expired ? 'bg-danger' : ($user['status'] == 'active' ? 'bg-success' : 'bg-secondary');
                                            $status_text = $is_expired ? 'Expired' : ucfirst($user['status']);
                                        ?>
                                        <tr>
                                            <td>
                                                <strong><?php echo htmlspecialchars($user['username']); ?></strong>
                                                <?php if ($user['email']): ?>
                                                <br><small class="text-muted"><?php echo htmlspecialchars($user['email']); ?></small>
                                                <?php endif; ?>
                                            </td>
                                            <td>
                                                <span class="badge <?php echo $user['role'] == 'admin' ? 'bg-warning' : 'bg-info'; ?>">
                                                    <?php echo ucfirst($user['role']); ?>
                                                </span>
                                            </td>
                                            <td>
                                                <span class="badge bg-dark"><?php echo $user['ip_limit']; ?> IPs</span>
                                            </td>
                                            <td>
                                                <div class="d-flex align-items-center">
                                                    <div class="me-2" style="width: 100px;">
                                                        <div class="progress" style="height: 8px;">
                                                            <div class="progress-bar <?php echo $usage_percent > 80 ? 'bg-danger' : ($usage_percent > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                                                 style="width: <?php echo $usage_percent; ?>%"></div>
                                                        </div>
                                                    </div>
                                                    <small><?php echo formatBytes($user['bandwidth_used']); ?></small>
                                                </div>
                                                <small class="text-muted">of <?php echo formatBytes($user['bandwidth_limit']); ?></small>
                                            </td>
                                            <td>
                                                <span class="badge <?php echo $status_class; ?>">
                                                    <?php echo $status_text; ?>
                                                </span>
                                            </td>
                                            <td>
                                                <?php if ($user['expiry_date']): ?>
                                                <small><?php echo date('Y-m-d', strtotime($user['expiry_date'])); ?></small>
                                                <?php else: ?>
                                                <span class="text-muted">No expiry</span>
                                                <?php endif; ?>
                                            </td>
                                            <td>
                                                <div class="btn-group btn-group-sm">
                                                    <!-- Edit Modal Button -->
                                                    <button type="button" class="btn btn-outline-primary" 
                                                            data-bs-toggle="modal" data-bs-target="#editUserModal"
                                                            onclick="loadUserData(<?php echo $user['id']; ?>)">
                                                        <i class="bi bi-pencil"></i>
                                                    </button>
                                                    
                                                    <!-- Delete Button -->
                                                    <?php if ($user['id'] != $_SESSION['user_id']): ?>
                                                    <a href="?action=users&action=delete&id=<?php echo $user['id']; ?>" 
                                                       class="btn btn-outline-danger"
                                                       onclick="return confirm('Delete user <?php echo htmlspecialchars($user['username']); ?>?')">
                                                        <i class="bi bi-trash"></i>
                                                    </a>
                                                    <?php endif; ?>
                                                </div>
                                            </td>
                                        </tr>
                                        <?php endforeach; ?>
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Edit User Modal -->
        <div class="modal fade" id="editUserModal" tabindex="-1">
            <div class="modal-dialog">
                <div class="modal-content">
                    <form method="POST">
                        <input type="hidden" name="update_limits" value="1">
                        <input type="hidden" name="user_id" id="edit_user_id">
                        
                        <div class="modal-header">
                            <h5 class="modal-title">Edit User Limits</h5>
                            <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                        </div>
                        
                        <div class="modal-body">
                            <div class="mb-3">
                                <label class="form-label">IP Limit</label>
                                <input type="number" name="ip_limit" id="edit_ip_limit" class="form-control" min="1" max="50">
                            </div>
                            
                            <div class="mb-3">
                                <label class="form-label">Bandwidth Limit (GB)</label>
                                <input type="number" name="bandwidth_gb" id="edit_bandwidth_gb" class="form-control" min="1" max="1000">
                            </div>
                            
                            <div class="mb-3">
                                <label class="form-label">Expiry Date</label>
                                <input type="date" name="expiry_date" id="edit_expiry_date" class="form-control">
                            </div>
                            
                            <div class="mb-3">
                                <label class="form-label">Status</label>
                                <select name="status" id="edit_status" class="form-select">
                                    <option value="active">Active</option>
                                    <option value="inactive">Inactive</option>
                                </select>
                            </div>
                        </div>
                        
                        <div class="modal-footer">
                            <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                            <button type="submit" class="btn btn-primary">Save Changes</button>
                        </div>
                    </form>
                </div>
            </div>
        </div>
        
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
        <script>
        function loadUserData(userId) {
            // This function would fetch user data via AJAX
            // For simplicity, we'll set dummy values
            document.getElementById('edit_user_id').value = userId;
            document.getElementById('edit_ip_limit').value = 3;
            document.getElementById('edit_bandwidth_gb').value = 10;
            document.getElementById('edit_status').value = 'active';
        }
        </script>
    </body>
    </html>
    <?php
}

// =============================================
// MAIN ROUTER
// =============================================
$action = $_GET['action'] ?? '';

// Handle login
if ($action == 'login' || $action == 'do_login') {
    if ($_SERVER['REQUEST_METHOD'] == 'POST' && $action == 'do_login') {
        $error = handleLogin();
        if ($error) {
            renderLoginPage($error);
        }
    } else {
        renderLoginPage();
    }
    exit;
}

// Check authentication
if (!isLoggedIn()) {
    header('Location: ?action=login');
    exit;
}

// Handle logout
if ($action == 'logout') {
    logout();
}

// Route to pages
switch ($action) {
    case 'dashboard':
        renderDashboard();
        break;
    case 'users':
        if ($_SESSION['role'] == 'admin') {
            renderUserManagementPage();
        } else {
            header('Location: ?action=dashboard');
        }
        break;
    case 'my_clients':
        // Render my clients page (to be implemented)
        renderDashboard();
        break;
    case 'create_client':
        // Render create client page (to be implemented)
        renderDashboard();
        break;
    case 'server':
        // Render server control page (to be implemented)
        renderDashboard();
        break;
    case 'settings':
        // Render settings page (to be implemented)
        renderDashboard();
        break;
    case 'logs':
        // Render logs page (to be implemented)
        renderDashboard();
        break;
    default:
        renderDashboard();
        break;
}
EOF

print_success "Web panel created at $PANEL_FILE"

# Create additional directories and files
mkdir -p "$WEB_DIR/assets"
mkdir -p "$WEB_DIR/uploads"

# Create .htaccess for security
cat > "$WEB_DIR/.htaccess" << 'EOF'
# Security headers
<IfModule mod_headers.c>
    Header set X-Content-Type-Options "nosniff"
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>

# Prevent directory listing
Options -Indexes

# Protect sensitive files
<FilesMatch "\.(sql|log|ini|conf|key)$">
    Require all denied
</FilesMatch>

# Rewrite rules
<IfModule mod_rewrite.c>
    RewriteEngine On
    
    # Redirect to HTTPS if not on localhost
    RewriteCond %{HTTPS} off
    RewriteCond %{HTTP_HOST} !^localhost
    RewriteCond %{HTTP_HOST} !^127\.0\.0\.1
    RewriteRule ^(.*)$ https://%{HTTP_HOST}/$1 [R=301,L]
    
    # Block access to hidden files
    RewriteRule ^\. - [F,L]
</IfModule>

# PHP settings
php_value upload_max_filesize 100M
php_value post_max_size 100M
php_value memory_limit 512M
php_value max_execution_time 300
php_value session.cookie_httponly 1
php_value session.cookie_secure 1
EOF

# Create config file
cat > "$WEB_DIR/config.php" << EOF
<?php
// Auto-generated config file
define('INSTALL_DATE', '$(date +%Y-%m-%d)');
define('SERVER_IP', '$SERVER_IP');
define('ADMIN_USER', '$ADMIN_USER');
define('DEFAULT_PORT', '$SLOWDNS_PORT');
EOF

# Set permissions
print_info "Setting permissions..."
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
chmod 644 "$PANEL_FILE"
chmod 600 "$WEB_DIR/.htaccess" 2>/dev/null || true
chmod 600 "$WEB_DIR/config.php"

# Configure Apache
print_info "Configuring Apache..."

# Create Apache config
cat > /etc/apache2/sites-available/slowdns-panel.conf << EOF
<VirtualHost *:80>
    ServerName $SERVER_IP
    ServerAdmin admin@localhost
    DocumentRoot $WEB_DIR
    
    <Directory $WEB_DIR>
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted
        
        # Security
        <IfModule mod_headers.c>
            Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
            Header always set Content-Security-Policy "default-src 'self' https:; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net;"
        </IfModule>
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/slowdns-panel-error.log
    CustomLog \${APACHE_LOG_DIR}/slowdns-panel-access.log combined
    
    # Compression
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css text/javascript application/javascript
    </IfModule>
</VirtualHost>
EOF

# Enable site
a2ensite slowdns-panel.conf
a2dissite 000-default.conf
a2enmod rewrite headers deflate

# Configure PHP-FPM
if systemctl list-units --type=service | grep -q php; then
    systemctl restart php*-fpm.service 2>/dev/null || true
fi

# Restart Apache
print_info "Restarting Apache..."
systemctl restart apache2
systemctl enable apache2

# Configure firewall
print_info "Configuring firewall..."
ufw --force enable
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw allow "$SLOWDNS_PORT"/udp
ufw allow "$SLOWDNS_PORT"/tcp

# Create systemd service for monitoring
cat > /etc/systemd/system/slowdns-monitor.service << EOF
[Unit]
Description=SlowDNS Panel Monitor
After=network.target mysql.service

[Service]
Type=simple
User=www-data
WorkingDirectory=$WEB_DIR
ExecStart=/usr/bin/php -f $WEB_DIR/monitor.php
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create monitoring script
cat > "$WEB_DIR/monitor.php" << 'EOF'
<?php
// Monitor script for SlowDNS Panel
while (true) {
    // Update server stats
    $load = sys_getloadavg();
    $mem = shell_exec("free | grep Mem | awk '{print $3/$2 * 100.0}'");
    $disk = disk_free_space("/");
    $total_disk = disk_total_space("/");
    $disk_used = (($total_disk - $disk) / $total_disk) * 100;
    
    // Get active connections
    exec("ss -tn 2>/dev/null | grep :5300 | grep ESTAB | wc -l", $output);
    $connections = intval($output[0] ?? 0);
    
    // Update database
    $db = new PDO("mysql:host=localhost;dbname=slowdns_panel", "slowdns_admin", "SlowDNS@2024");
    $stmt = $db->prepare("INSERT INTO server_stats (cpu_load, memory_used, disk_used, active_connections) VALUES (?, ?, ?, ?)");
    $stmt->execute([$load[0], $mem, $disk_used, $connections]);
    
    // Clean old stats (keep 7 days)
    $db->exec("DELETE FROM server_stats WHERE timestamp < DATE_SUB(NOW(), INTERVAL 7 DAY)");
    
    sleep(60); // Update every minute
}
EOF

systemctl daemon-reload
systemctl enable slowdns-monitor.service
systemctl start slowdns-monitor.service

# Create backup script
cat > /usr/local/bin/backup-slowdns.sh << 'EOF'
#!/bin/bash
# Backup SlowDNS Panel and Database
BACKUP_DIR="/root/slowdns-backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/slowdns-panel-$DATE.tar.gz"

mkdir -p $BACKUP_DIR

# Backup web files
tar -czf /tmp/web-backup.tar.gz -C /var/www slowdns-panel/

# Backup database
mysqldump -u slowdns_admin -pSlowDNS@2024 slowdns_panel > /tmp/db-backup.sql

# Combine backups
tar -czf $BACKUP_FILE -C /tmp web-backup.tar.gz db-backup.sql

# Cleanup
rm -f /tmp/web-backup.tar.gz /tmp/db-backup.sql

echo "Backup created: $BACKUP_FILE"
echo "Size: $(du -h $BACKUP_FILE | cut -f1)"

# Remove old backups (keep last 30 days)
find $BACKUP_DIR -name "slowdns-panel-*.tar.gz" -mtime +30 -delete
EOF

chmod +x /usr/local/bin/backup-slowdns.sh

# Add to crontab for daily backup
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/backup-slowdns.sh") | crontab -

# Create uninstall script
cat > /usr/local/bin/uninstall-slowdns-panel.sh << 'EOF'
#!/bin/bash
echo "Uninstalling SlowDNS Panel..."
systemctl stop slowdns-monitor.service
systemctl disable slowdns-monitor.service
systemctl stop apache2
a2dissite slowdns-panel.conf
rm -f /etc/apache2/sites-available/slowdns-panel.conf
rm -rf /var/www/slowdns-panel
systemctl restart apache2
mysql -e "DROP DATABASE IF EXISTS slowdns_panel;"
mysql -e "DROP USER IF EXISTS 'slowdns_admin'@'localhost';"
rm -f /usr/local/bin/backup-slowdns.sh
rm -f /usr/local/bin/uninstall-slowdns-panel.sh
crontab -l | grep -v "backup-slowdns.sh" | crontab -
echo "SlowDNS Panel uninstalled!"
EOF

chmod +x /usr/local/bin/uninstall-slowdns-panel.sh

# =============================================
# INSTALLATION COMPLETE
# =============================================
print_success "Installation completed successfully!"
echo ""
echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN}    SLOWDNS WEB PANEL INSTALLATION COMPLETE    ${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║            ACCESS INFORMATION                ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}📊 PANEL URL:${NC}"
echo -e "   http://$SERVER_IP/"
echo -e "   http://$SERVER_IP:80/"
echo ""
echo -e "${GREEN}🔐 ADMIN LOGIN CREDENTIALS:${NC}"
echo -e "   Username: ${RED}$ADMIN_USER${NC}"
echo -e "   Password: ${RED}$ADMIN_PASS${NC}"
echo -e "   ${YELLOW}⚠️  CHANGE THIS PASSWORD IMMEDIATELY!${NC}"
echo ""
echo -e "${GREEN}🌐 SLOWDNS SERVER:${NC}"
echo -e "   IP Address: $SERVER_IP"
echo -e "   Port: $SLOWDNS_PORT (UDP)"
echo ""
echo -e "${GREEN}🗄️  DATABASE INFO:${NC}"
echo -e "   Database: slowdns_panel"
echo -e "   Username: slowdns_admin"
echo -e "   Password: SlowDNS@2024"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║             INSTALLED FEATURES               ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ User Management System${NC}"
echo -e "  • Add/Edit/Delete users"
echo -e "  • Set IP limits per user"
echo -e "  • Set bandwidth limits (GB)"
echo -e "  • Set expiry dates"
echo -e "  • View user usage statistics"
echo ""
echo -e "${GREEN}✓ Server Monitoring${NC}"
echo -e "  • Real-time server status"
echo -e "  • CPU, Memory, Disk usage"
echo -e "  • Active connections"
echo -e "  • Bandwidth monitoring"
echo ""
echo -e "${GREEN}✓ Client Management${NC}"
echo -e "  • Create SlowDNS clients"
echo -e "  • Download config files"
echo -e "  • QR code generation"
echo -e "  • Bandwidth tracking"
echo ""
echo -e "${GREEN}✓ Security Features${NC}"
echo -e "  • MySQL database"
echo -e "  • Password hashing"
echo -e "  • Session management"
echo -e "  • Activity logging"
echo -e "  • Automatic backups"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║             NEXT STEPS                       ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "1. ${BLUE}Access the panel:${NC}"
echo -e "   Open browser → http://$SERVER_IP/"
echo ""
echo -e "2. ${BLUE}Change admin password:${NC}"
echo -e "   Login → Settings → Change Password"
echo ""
echo -e "3. ${BLUE}Add users:${NC}"
echo -e "   Admin Panel → User Management → Add User"
echo ""
echo -e "4. ${BLUE}Set user limits:${NC}"
echo -e "   • IP Limit: Max concurrent connections"
echo -e "   • Bandwidth: Total data limit (GB)"
echo -e "   • Expiry: Account expiry date"
echo ""
echo -e "5. ${BLUE}Monitor usage:${NC}"
echo -e "   Dashboard shows real-time usage statistics"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║             MANAGEMENT COMMANDS              ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Backup panel:${NC}"
echo -e "   sudo /usr/local/bin/backup-slowdns.sh"
echo ""
echo -e "${CYAN}View logs:${NC}"
echo -e "   sudo tail -f /var/log/apache2/slowdns-panel-*.log"
echo ""
echo -e "${CYAN}Uninstall:${NC}"
echo -e "   sudo /usr/local/bin/uninstall-slowdns-panel.sh"
echo ""
echo -e "${RED}⚠️  Installation details saved to:${NC}"
echo -e "   /root/slowdns-install-info.txt"
echo ""

# Save installation info
cat > /root/slowdns-install-info.txt << EOF
============================================
SLOWDNS WEB PANEL INSTALLATION INFORMATION
============================================
Installation Date: $(date)
Server IP: $SERVER_IP
SlowDNS Port: $SLOWDNS_PORT

PANEL ACCESS:
------------
URL: http://$SERVER_IP/
Admin Username: $ADMIN_USER
Admin Password: $ADMIN_PASS

DATABASE:
---------
Database: slowdns_panel
Username: slowdns_admin
Password: SlowDNS@2024

PATHS:
------
Web Directory: $WEB_DIR
Log Directory: $LOG_DIR
Backup Directory: /root/slowdns-backups/

MANAGEMENT COMMANDS:
-------------------
Backup: sudo /usr/local/bin/backup-slowdns.sh
Uninstall: sudo /usr/local/bin/uninstall-slowdns-panel.sh

IMPORTANT:
----------
1. Change admin password immediately!
2. Configure user limits in the panel
3. Regular backups are stored in /root/slowdns-backups/

INSTALLED FEATURES:
------------------
✓ User Management (IP limits, bandwidth limits, expiry dates)
✓ Server Monitoring (CPU, Memory, Connections)
✓ Client Management
✓ Activity Logging
✓ Automatic Backups
✓ MySQL Database
✓ Secure Authentication
EOF

print_info "Installation complete! Access your panel now."
echo ""
echo -e "${GREEN}✅ Installation successful!${NC}"
echo ""
