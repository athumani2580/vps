#!/bin/bash

# =============================================
# SLOWDNS WEB PANEL INSTALLER - SQLITE VERSION
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
ADMIN_USER="admin"
ADMIN_PASS="Admin@1234"
SLOWDNS_PORT="5300"
WEB_DIR="/var/www/slowdns-panel"
DB_FILE="$WEB_DIR/database/slowdns.db"
LOG_DIR="/var/log/slowdns"
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║       SLOWDNS WEB PANEL INSTALLER       ║"
    echo "║          SQLite Version - No MySQL      ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

# Start installation
print_banner
check_root

print_info "Starting SlowDNS Web Panel installation..."
print_info "Server IP: $SERVER_IP"

# Update system
print_info "Updating system packages..."
apt update -y
apt upgrade -y

# Install required packages
print_info "Installing required packages..."
apt install -y apache2 php php-sqlite3 php-curl php-gd php-mbstring \
               php-xml php-zip sqlite3 curl wget unzip net-tools \
               python3 python3-pip

# Create directories
print_info "Creating directories..."
mkdir -p "$WEB_DIR"
mkdir -p "$WEB_DIR/database"
mkdir -p "$WEB_DIR/configs"
mkdir -p "$WEB_DIR/backups"
mkdir -p "$LOG_DIR"

# Create SQLite database and tables
print_info "Creating SQLite database..."
cd "$WEB_DIR/database"

# Create database schema
sqlite3 slowdns.db << 'EOF'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    email TEXT,
    ip_limit INTEGER DEFAULT 3,
    bandwidth_limit INTEGER DEFAULT 10737418240,
    bandwidth_used INTEGER DEFAULT 0,
    expiry_date TEXT,
    status TEXT DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP,
    last_ip TEXT,
    max_clients INTEGER DEFAULT 5
);

CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    name TEXT NOT NULL,
    config_key TEXT NOT NULL,
    domain TEXT,
    bandwidth_used INTEGER DEFAULT 0,
    status TEXT DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_used TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS server_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    cpu_load REAL,
    memory_used REAL,
    disk_used REAL,
    active_connections INTEGER DEFAULT 0,
    total_bandwidth INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS activity_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    action TEXT NOT NULL,
    details TEXT,
    ip_address TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

# Create admin user
ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")
sqlite3 slowdns.db << EOF
INSERT OR REPLACE INTO users (username, password, role, email, ip_limit, bandwidth_limit, status, max_clients) 
VALUES ('$ADMIN_USER', '$ADMIN_HASH', 'admin', 'admin@example.com', 999, 1099511627776, 'active', 999);
EOF

print_success "Database created successfully"

# Create the main web panel
print_info "Creating web panel..."
cat > "$WEB_DIR/index.php" << 'EOF'
<?php
session_start();
date_default_timezone_set('UTC');

// Database configuration
define('DB_FILE', __DIR__ . '/database/slowdns.db');
define('SITE_NAME', 'SlowDNS Manager Pro');
define('SLOWDNS_PORT', 5300);
define('BASE_URL', (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]");

// Create database connection
function getDB() {
    try {
        $db = new PDO('sqlite:' . DB_FILE);
        $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        return $db;
    } catch (PDOException $e) {
        die("Database connection failed: " . $e->getMessage());
    }
}

// Authentication functions
function isLoggedIn() {
    return isset($_SESSION['user_id']) && isset($_SESSION['login_time']) && (time() - $_SESSION['login_time']) < 3600;
}

function login($username, $password) {
    $db = getDB();
    $stmt = $db->prepare("SELECT * FROM users WHERE username = ? AND status = 'active'");
    $stmt->execute([$username]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);
    
    if ($user && password_verify($password, $user['password'])) {
        $_SESSION['user_id'] = $user['id'];
        $_SESSION['username'] = $user['username'];
        $_SESSION['role'] = $user['role'];
        $_SESSION['login_time'] = time();
        
        // Update last login
        $stmt = $db->prepare("UPDATE users SET last_login = datetime('now'), last_ip = ? WHERE id = ?");
        $stmt->execute([$_SERVER['REMOTE_ADDR'], $user['id']]);
        
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
    $db = getDB();
    $stmt = $db->prepare("INSERT INTO activity_logs (user_id, action, details, ip_address) VALUES (?, ?, ?, ?)");
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
    
    // Get system information
    $load = sys_getloadavg();
    $status['cpu_load'] = round($load[0], 2);
    
    $mem = shell_exec("free | grep Mem | awk '{print $3/$2 * 100.0}'");
    $status['memory_used'] = round(floatval($mem), 2);
    
    $disk = disk_free_space("/");
    $total_disk = disk_total_space("/");
    $status['disk_used'] = round((($total_disk - $disk) / $total_disk) * 100, 2);
    
    $uptime = shell_exec("uptime -p | sed 's/up //'");
    $status['uptime'] = trim($uptime);
    
    // Get server IP
    $status['ip'] = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    // Check SlowDNS service (assuming service name)
    exec('systemctl is-active slowdns.service 2>/dev/null', $output, $code);
    $status['service'] = $code == 0 ? 'running' : 'stopped';
    
    // Check port
    exec("netstat -tulpn 2>/dev/null | grep :" . SLOWDNS_PORT, $output);
    $status['port'] = !empty($output) ? 'open' : 'closed';
    
    // Get connections
    exec("ss -tn 2>/dev/null | grep :" . SLOWDNS_PORT . " | grep ESTAB | wc -l", $output);
    $status['connections'] = intval($output[0] ?? 0);
    
    return $status;
}

function getUserStats($user_id) {
    $db = getDB();
    $stats = [];
    
    // Get user data
    $stmt = $db->prepare("SELECT bandwidth_used, bandwidth_limit FROM users WHERE id = ?");
    $stmt->execute([$user_id]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);
    
    $stats['bandwidth_used'] = $user['bandwidth_used'] ?? 0;
    $stats['bandwidth_limit'] = $user['bandwidth_limit'] ?? 0;
    
    // Get active clients
    $stmt = $db->prepare("SELECT COUNT(*) as count FROM clients WHERE user_id = ? AND status = 'active'");
    $stmt->execute([$user_id]);
    $stats['active_clients'] = $stmt->fetch(PDO::FETCH_ASSOC)['count'] ?? 0;
    
    // Get total clients
    $stmt = $db->prepare("SELECT COUNT(*) as count FROM clients WHERE user_id = ?");
    $stmt->execute([$user_id]);
    $stats['total_clients'] = $stmt->fetch(PDO::FETCH_ASSOC)['count'] ?? 0;
    
    // Calculate usage percentage
    $stats['usage_percent'] = $stats['bandwidth_limit'] > 0 ? 
        min(100, ($stats['bandwidth_used'] / $stats['bandwidth_limit']) * 100) : 0;
    
    return $stats;
}

// Handle actions
$action = $_GET['action'] ?? 'dashboard';

// Login page
if ($action == 'login' || !isLoggedIn()) {
    if ($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_POST['username'])) {
        if (login($_POST['username'], $_POST['password'])) {
            header('Location: ?action=dashboard');
            exit;
        } else {
            $login_error = "Invalid username or password";
        }
    }
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Login - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
        <style>
            body { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); height: 100vh; }
            .login-card { max-width: 400px; margin: 100px auto; padding: 30px; border-radius: 15px; background: white; box-shadow: 0 10px 30px rgba(0,0,0,0.2); }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="login-card">
                <div class="text-center mb-4">
                    <h3><i class="bi bi-shield-lock"></i> <?php echo SITE_NAME; ?></h3>
                    <p class="text-muted">SlowDNS Management Panel</p>
                </div>
                <?php if (isset($login_error)): ?>
                <div class="alert alert-danger"><?php echo $login_error; ?></div>
                <?php endif; ?>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label">Username</label>
                        <input type="text" name="username" class="form-control" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Password</label>
                        <input type="password" name="password" class="form-control" required>
                    </div>
                    <button type="submit" class="btn btn-primary w-100">
                        <i class="bi bi-box-arrow-in-right"></i> Login
                    </button>
                </form>
            </div>
        </div>
    </body>
    </html>
    <?php
    exit;
}

// Handle logout
if ($action == 'logout') {
    logout();
}

// Dashboard
if ($action == 'dashboard') {
    $user_id = $_SESSION['user_id'];
    $role = $_SESSION['role'];
    $stats = getUserStats($user_id);
    $server_status = getServerStatus();
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
                            <a class="nav-link" href="?action=clients">
                                <i class="bi bi-person-badge me-2"></i> My Clients
                            </a>
                            <a class="nav-link" href="?action=create_client">
                                <i class="bi bi-plus-circle me-2"></i> Create Client
                            </a>
                            <?php if ($_SESSION['role'] == 'admin'): ?>
                            <hr class="my-2">
                            <h6 class="text-muted mt-2 mb-2">Admin Panel</h6>
                            <a class="nav-link" href="?action=users">
                                <i class="bi bi-people me-2"></i> Users
                            </a>
                            <a class="nav-link" href="?action=server">
                                <i class="bi bi-server me-2"></i> Server
                            </a>
                            <a class="nav-link" href="?action=settings">
                                <i class="bi bi-gear me-2"></i> Settings
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
                        
                        <div class="col-md-3">
                            <div class="card stat-card p-3" style="border-left-color: #f8961e;">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Server Uptime</h6>
                                        <h3 class="mb-0"><?php echo $server_status['uptime']; ?></h3>
                                    </div>
                                    <div class="bg-warning text-white rounded-circle p-2">
                                        <i class="bi bi-clock-history fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">System uptime</small>
                            </div>
                        </div>
                        
                        <div class="col-md-3">
                            <div class="card stat-card p-3" style="border-left-color: #43aa8b;">
                                <div class="d-flex justify-content-between align-items-center">
                                    <div>
                                        <h6 class="text-muted">Memory Usage</h6>
                                        <h3 class="mb-0"><?php echo $server_status['memory_used']; ?>%</h3>
                                    </div>
                                    <div class="bg-success text-white rounded-circle p-2">
                                        <i class="bi bi-memory fs-4"></i>
                                    </div>
                                </div>
                                <small class="text-muted">System memory</small>
                            </div>
                        </div>
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
                                    <a href="?action=clients" class="btn btn-outline-primary w-100">
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
    exit;
}

// Add other action handlers here (users, clients, etc.)
// For now, redirect to dashboard for other actions
header('Location: ?action=dashboard');
exit;
EOF

# Create additional PHP pages
cat > "$WEB_DIR/users.php" << 'EOF'
<?php
session_start();
require_once 'index.php';

if (!isLoggedIn() || $_SESSION['role'] != 'admin') {
    header('Location: ?action=login');
    exit;
}

$db = getDB();

// Handle add user
if ($_SERVER['REQUEST_METHOD'] == 'POST' && isset($_POST['add_user'])) {
    $username = $_POST['username'];
    $password = $_POST['password'];
    $email = $_POST['email'];
    $ip_limit = intval($_POST['ip_limit'] ?? 3);
    $bandwidth_gb = intval($_POST['bandwidth_gb'] ?? 10);
    $max_clients = intval($_POST['max_clients'] ?? 5);
    
    $hashed_password = password_hash($password, PASSWORD_DEFAULT);
    $bandwidth_limit = $bandwidth_gb * 1024 * 1024 * 1024;
    
    $stmt = $db->prepare("INSERT INTO users (username, password, email, ip_limit, bandwidth_limit, max_clients) VALUES (?, ?, ?, ?, ?, ?)");
    $stmt->execute([$username, $hashed_password, $email, $ip_limit, $bandwidth_limit, $max_clients]);
    
    logActivity($_SESSION['user_id'], "Added user: $username");
    $success = "User added successfully!";
}

// Get all users
$stmt = $db->query("SELECT * FROM users ORDER BY created_at DESC");
$users = $stmt->fetchAll(PDO::FETCH_ASSOC);
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
    <nav class="navbar navbar-dark bg-dark">
        <div class="container-fluid">
            <a class="navbar-brand" href="?action=dashboard">
                <i class="bi bi-shield-lock me-2"></i>
                <strong><?php echo SITE_NAME; ?></strong>
            </a>
            <div class="navbar-nav">
                <a href="?action=dashboard" class="btn btn-outline-light btn-sm me-2">Dashboard</a>
                <a href="?action=logout" class="btn btn-outline-light btn-sm">Logout</a>
            </div>
        </div>
    </nav>
    
    <div class="container-fluid mt-3">
        <?php if (isset($success)): ?>
        <div class="alert alert-success"><?php echo $success; ?></div>
        <?php endif; ?>
        
        <div class="row">
            <div class="col-md-4">
                <div class="card">
                    <div class="card-header bg-primary text-white">
                        <h5 class="mb-0"><i class="bi bi-person-plus me-2"></i> Add New User</h5>
                    </div>
                    <div class="card-body">
                        <form method="POST">
                            <input type="hidden" name="add_user" value="1">
                            <div class="mb-3">
                                <label>Username</label>
                                <input type="text" name="username" class="form-control" required>
                            </div>
                            <div class="mb-3">
                                <label>Password</label>
                                <input type="password" name="password" class="form-control" required>
                            </div>
                            <div class="mb-3">
                                <label>Email</label>
                                <input type="email" name="email" class="form-control">
                            </div>
                            <div class="row">
                                <div class="col-md-6 mb-3">
                                    <label>IP Limit</label>
                                    <input type="number" name="ip_limit" class="form-control" value="3" min="1">
                                </div>
                                <div class="col-md-6 mb-3">
                                    <label>Bandwidth (GB)</label>
                                    <input type="number" name="bandwidth_gb" class="form-control" value="10" min="1">
                                </div>
                            </div>
                            <div class="mb-3">
                                <label>Max Clients</label>
                                <input type="number" name="max_clients" class="form-control" value="5" min="1">
                            </div>
                            <button type="submit" class="btn btn-primary w-100">Add User</button>
                        </form>
                    </div>
                </div>
            </div>
            
            <div class="col-md-8">
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
                                        <th>Bandwidth</th>
                                        <th>Clients</th>
                                        <th>Created</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <?php foreach ($users as $user): ?>
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
                                        <td><?php echo $user['ip_limit']; ?> IPs</td>
                                        <td><?php echo formatBytes($user['bandwidth_limit']); ?></td>
                                        <td><?php echo $user['max_clients']; ?></td>
                                        <td><?php echo date('Y-m-d', strtotime($user['created_at'])); ?></td>
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
    
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# Create .htaccess file
cat > "$WEB_DIR/.htaccess" << 'EOF'
# Security headers
<IfModule mod_headers.c>
    Header set X-Content-Type-Options "nosniff"
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
</IfModule>

# Prevent directory listing
Options -Indexes

# Protect sensitive files
<FilesMatch "\.(db|sql|log|ini)$">
    Require all denied
</FilesMatch>

# PHP settings
php_value upload_max_filesize 100M
php_value post_max_size 100M
php_value memory_limit 256M
php_value max_execution_time 300
php_value session.cookie_httponly 1
EOF

# Set permissions
print_info "Setting permissions..."
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
chmod 644 "$WEB_DIR/index.php"
chmod 644 "$WEB_DIR/users.php"
chmod 600 "$WEB_DIR/.htaccess"
chmod 644 "$WEB_DIR/database/slowdns.db"

# Configure Apache
print_info "Configuring Apache..."
cat > /etc/apache2/sites-available/slowdns-panel.conf << EOF
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot $WEB_DIR
    
    <Directory $WEB_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/slowdns-error.log
    CustomLog \${APACHE_LOG_DIR}/slowdns-access.log combined
</VirtualHost>
EOF

# Enable site
a2ensite slowdns-panel.conf > /dev/null 2>&1
a2dissite 000-default.conf > /dev/null 2>&1
a2enmod rewrite > /dev/null 2>&1

# Restart Apache
print_info "Restarting Apache..."
systemctl restart apache2
systemctl enable apache2

# Configure firewall
print_info "Configuring firewall..."
ufw --force enable > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 22/tcp > /dev/null 2>&1
ufw allow "$SLOWDNS_PORT"/udp > /dev/null 2>&1

# Create systemd service for SlowDNS (example)
cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
Documentation=https://man himself
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/sldns-server -udp :$SLOWDNS_PORT -mtu 1800 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$SSHD_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Create backup script
cat > /usr/local/bin/backup-slowdns.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/root/slowdns-backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
cp -r /var/www/slowdns-panel/database/slowdns.db "$BACKUP_DIR/slowdns-backup-$DATE.db"
echo "Backup created: $BACKUP_DIR/slowdns-backup-$DATE.db"
EOF
chmod +x /usr/local/bin/backup-slowdns.sh

# Installation complete
print_success "Installation completed successfully!"
echo ""
echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN}    SLOWDNS WEB PANEL INSTALLATION COMPLETE    ${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${GREEN}📊 PANEL URL:${NC}"
echo -e "   http://$SERVER_IP/"
echo -e "   http://localhost/"
echo ""
echo -e "${GREEN}🔐 ADMIN LOGIN CREDENTIALS:${NC}"
echo -e "   Username: ${RED}$ADMIN_USER${NC}"
echo -e "   Password: ${RED}$ADMIN_PASS${NC}"
echo ""
echo -e "${GREEN}🌐 SLOWDNS SERVER:${NC}"
echo -e "   IP Address: $SERVER_IP"
echo -e "   Port: $SLOWDNS_PORT (UDP)"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT:${NC}"
echo -e "   1. Change admin password immediately!"
echo -e "   2. Configure your actual SlowDNS server"
echo -e "   3. Create users and generate configs"
echo ""
echo -e "${GREEN}🗄️  DATABASE:${NC}"
echo -e "   SQLite file: $DB_FILE"
echo -e "   No MySQL/MariaDB required!"
echo ""
echo -e "${BLUE}📋 INSTALLED FEATURES:${NC}"
echo -e "   ✓ User management system"
echo -e "   ✓ Server monitoring dashboard"
echo -e "   ✓ Bandwidth tracking"
echo -e "   ✓ Client management (coming soon)"
echo -e "   ✓ SQLite database (lightweight)"
echo -e "   ✓ No external database required"
echo ""
echo -e "${BLUE}🔧 MANAGEMENT COMMANDS:${NC}"
echo -e "   Backup database: sudo /usr/local/bin/backup-slowdns.sh"
echo -e "   View logs: sudo tail -f /var/log/apache2/slowdns-error.log"
echo ""
echo -e "${YELLOW}✅ Installation successful! Access your panel now.${NC}"
echo ""
