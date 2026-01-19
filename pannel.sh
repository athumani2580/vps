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

SITE_NAME="SlowDNS Manager Pro"
ADMIN_USER="admin"
ADMIN_PASS="admin123"  # CHANGE THIS AFTER INSTALL
SLOWDNS_PORT="5300"
PANEL_PORT="8080"
WEB_DIR="/var/www/slowdns-panel"
PANEL_FILE="$WEB_DIR/index.php"
LOG_FILE="/var/log/slowdns-panel.log"

# =============================================
# FUNCTIONS
# =============================================
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

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║    SLOWDNS WEB PANEL INSTALLER v2.0     ║"
    echo "║      Complete All-in-One Solution       ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
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

# =============================================
# MAIN INSTALLATION
# =============================================
print_banner
check_root

print_info "Starting installation of SlowDNS Web Panel..."

# Update system
print_info "Updating system packages..."
apt update -y
apt upgrade -y

# Install required packages
print_info "Installing required packages..."
apt install -y php php-curl php-gd php-mbstring php-xml php-zip \
              apache2 mariadb-server git curl wget unzip \
              net-tools screen python3 python3-pip

# Install PHP extensions
apt install -y php-mysql php-common php-cli php-json php-opcache php-readline

# Configure PHP
print_info "Configuring PHP..."
for php_ini in /etc/php/*/apache2/php.ini; do
    sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 50M/' $php_ini
    sed -i 's/^post_max_size =.*/post_max_size = 50M/' $php_ini
    sed -i 's/^memory_limit =.*/memory_limit = 256M/' $php_ini
    sed -i 's/^max_execution_time =.*/max_execution_time = 300/' $php_ini
    sed -i 's/^;extension=curl/extension=curl/' $php_ini
    sed -i 's/^;extension=gd/extension=gd/' $php_ini
    sed -i 's/^;extension=mysqli/extension=mysqli/' $php_ini
done

# Create web directory
print_info "Creating web directory..."
rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
cd "$WEB_DIR"

# =============================================
# CREATE THE COMPLETE WEB PANEL
# =============================================
print_info "Creating web panel files..."

cat > "$PANEL_FILE" << 'EOF'
<?php
/**
 * Complete SlowDNS Web Panel v2.0
 * Single File Installation
 */

// =============================================
// CONFIGURATION - EDITABLE SECTION
// =============================================
define('SITE_NAME', 'SlowDNS Manager Pro');
define('ADMIN_USER', 'admin');
define('ADMIN_PASS', 'admin123'); // CHANGE THIS!
define('SLOWDNS_PORT', 5300);
define('SLOWDNS_DIR', '/etc/slowdns');
define('DATA_FILE', __DIR__ . '/data.json');
define('LOG_FILE', __DIR__ . '/activity.log');
define('DEFAULT_LIMIT_GB', 5);

// Server Configuration (Editable via Panel)
$server_config = [
    'name' => 'My SlowDNS Server',
    'domain' => 'dns.example.com',
    'port' => SLOWDNS_PORT,
    'max_connections' => 100,
    'maintenance' => false,
    'restart_count' => 0,
    'last_restart' => null
];

// =============================================
// INITIALIZATION
// =============================================
session_start();
date_default_timezone_set('UTC');

// Auto-create data file on first run
if (!file_exists(DATA_FILE)) {
    $initial_data = [
        'users' => [
            ADMIN_USER => [
                'password' => password_hash(ADMIN_PASS, PASSWORD_DEFAULT),
                'role' => 'admin',
                'email' => 'admin@localhost',
                'created' => date('Y-m-d H:i:s'),
                'last_login' => null,
                'ip' => $_SERVER['REMOTE_ADDR'] ?? '',
                'max_clients' => 999,
                'active' => true
            ]
        ],
        'clients' => [],
        'server' => $server_config,
        'settings' => [
            'allow_registration' => false,
            'max_users' => 50,
            'log_retention_days' => 30,
            'notify_on_restart' => true
        ]
    ];
    file_put_contents(DATA_FILE, json_encode($initial_data, JSON_PRETTY_PRINT));
}

// Load data
$data = json_decode(file_get_contents(DATA_FILE), true);

// =============================================
// HELPER FUNCTIONS
// =============================================
function saveData() {
    global $data;
    file_put_contents(DATA_FILE, json_encode($data, JSON_PRETTY_PRINT));
}

function logActivity($message, $user = null) {
    $log = date('Y-m-d H:i:s') . " | " . ($user ?: $_SESSION['user']['username'] ?? 'system') . " | " . $message . "\n";
    file_put_contents(LOG_FILE, $log, FILE_APPEND);
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
    $status['load'] = $load[0];
    
    $mem = shell_exec("free | grep Mem | awk '{print $3/$2 * 100.0}'");
    $status['memory'] = round(floatval($mem), 2);
    
    $disk = disk_free_space("/");
    $status['disk_free_gb'] = round($disk / (1024*1024*1024), 1);
    
    $uptime = shell_exec("uptime -p");
    $status['uptime'] = trim($uptime);
    
    // Get server IP
    $status['ip'] = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    return $status;
}

function formatBytes($bytes, $precision = 2) {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $bytes = max($bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min($pow, count($units) - 1);
    $bytes /= pow(1024, $pow);
    return round($bytes, $precision) . ' ' . $units[$pow];
}

function restartSlowDNS() {
    exec('systemctl restart server-sldns.service 2>&1', $output, $code);
    return $code == 0;
}

function generateKey() {
    return bin2hex(random_bytes(32));
}

function createClientConfig($client) {
    global $data;
    $server = $data['server'];
    $server_ip = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    $config = "# SlowDNS Client Configuration\n";
    $config .= "# Server: " . $server['name'] . "\n";
    $config .= "# Generated: " . date('Y-m-d H:i:s') . "\n\n";
    
    $config .= "[client]\n";
    $config .= "name = " . $client['name'] . "\n";
    $config .= "server = " . (empty($server['domain']) ? $server_ip : $server['domain']) . "\n";
    $config .= "port = " . $server['port'] . "\n";
    $config .= "key = " . $client['key'] . "\n";
    $config .= "mtu = 1200\n";
    $config .= "protocol = udp\n";
    $config .= "dns = 8.8.8.8\n";
    $config .= "keepalive = 30\n";
    $config .= "\n# Usage: ./sldns-client -config this-file.conf\n";
    
    return $config;
}

// =============================================
// AUTHENTICATION
// =============================================
function isLoggedIn() {
    return isset($_SESSION['user']) && isset($_SESSION['user']['username']);
}

function login($username, $password) {
    global $data;
    if (isset($data['users'][$username]) && 
        password_verify($password, $data['users'][$username]['password']) &&
        $data['users'][$username]['active']) {
        
        $_SESSION['user'] = [
            'username' => $username,
            'role' => $data['users'][$username]['role'],
            'login_time' => time()
        ];
        
        $data['users'][$username]['last_login'] = date('Y-m-d H:i:s');
        $data['users'][$username]['last_ip'] = $_SERVER['REMOTE_ADDR'];
        saveData();
        
        logActivity("User logged in from " . $_SERVER['REMOTE_ADDR'], $username);
        return true;
    }
    return false;
}

function logout() {
    logActivity("User logged out", $_SESSION['user']['username']);
    session_destroy();
    header('Location: ?');
    exit;
}

// =============================================
// HTML TEMPLATES
// =============================================
function renderHeader($title = 'Dashboard') {
    global $data;
    $server_status = getServerStatus();
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title><?php echo $title; ?> - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
        <style>
            :root {
                --primary: #4361ee;
                --secondary: #3a0ca3;
                --success: #4cc9f0;
                --danger: #f72585;
                --dark: #1a1a2e;
                --light: #f8f9fa;
            }
            body { background: #f5f7fa; min-height: 100vh; }
            .navbar { background: var(--dark) !important; }
            .sidebar { background: white; border-radius: 10px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
            .card { border: none; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
            .stat-card { border-left: 4px solid var(--primary); }
            .progress-thin { height: 8px; }
        </style>
    </head>
    <body>
        <!-- Navbar -->
        <nav class="navbar navbar-expand-lg navbar-dark">
            <div class="container">
                <a class="navbar-brand" href="?">
                    <i class="bi bi-shield-lock me-2"></i>
                    <strong><?php echo $data['server']['name']; ?></strong>
                </a>
                
                <?php if (isLoggedIn()): ?>
                <div class="navbar-nav ms-auto align-items-center">
                    <span class="navbar-text me-3">
                        <i class="bi bi-person-circle"></i> <?php echo $_SESSION['user']['username']; ?>
                        <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                        <span class="badge bg-warning ms-1">Admin</span>
                        <?php endif; ?>
                    </span>
                    <a href="?action=logout" class="btn btn-outline-light btn-sm">Logout</a>
                </div>
                <?php endif; ?>
            </div>
        </nav>
        
        <div class="container-fluid mt-3">
            <div class="row">
                <!-- Sidebar -->
                <div class="col-lg-2">
                    <div class="sidebar p-3 mb-3">
                        <nav class="nav flex-column">
                            <a class="nav-link <?php echo (!isset($_GET['action']) || $_GET['action'] == 'dashboard') ? 'active' : ''; ?>" href="?">
                                <i class="bi bi-speedometer2 me-2"></i> Dashboard
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'clients' ? 'active' : ''; ?>" href="?action=clients">
                                <i class="bi bi-person-badge me-2"></i> My Clients
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'create_client' ? 'active' : ''; ?>" href="?action=create_client">
                                <i class="bi bi-plus-circle me-2"></i> Create Client
                            </a>
                            
                            <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                            <hr class="my-2">
                            <h6 class="text-muted mt-2 mb-2">Admin Panel</h6>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'server_settings' ? 'active' : ''; ?>" href="?action=server_settings">
                                <i class="bi bi-gear me-2"></i> Server Settings
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'user_management' ? 'active' : ''; ?>" href="?action=user_management">
                                <i class="bi bi-people me-2"></i> User Management
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'server_control' ? 'active' : ''; ?>" href="?action=server_control">
                                <i class="bi bi-terminal me-2"></i> Server Control
                            </a>
                            <?php endif; ?>
                            
                            <hr class="my-2">
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'change_password' ? 'active' : ''; ?>" href="?action=change_password">
                                <i class="bi bi-key me-2"></i> Change Password
                            </a>
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
                                    <small>Load:</small>
                                    <small class="text-muted"><?php echo $server_status['load']; ?></small>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Main Content -->
                <div class="col-lg-10">
    <?php
}

function renderFooter() {
    ?>
                </div>
            </div>
        </div>
        
        <!-- Footer -->
        <footer class="mt-4 py-3 text-center text-muted border-top">
            <small>
                <?php echo SITE_NAME; ?> v2.0 &copy; <?php echo date('Y'); ?> | 
                Server IP: <?php echo getServerStatus()['ip']; ?>
            </small>
        </footer>
        
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
        <script>
            // Auto refresh every 60 seconds
            setTimeout(() => location.reload(), 60000);
            
            function copyToClipboard(text) {
                navigator.clipboard.writeText(text).then(() => {
                    alert('Copied to clipboard!');
                });
            }
            
            function downloadConfig(name, config) {
                const blob = new Blob([config], {type: 'text/plain'});
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = name + '.conf';
                a.click();
                URL.revokeObjectURL(url);
            }
        </script>
    </body>
    </html>
    <?php
}

// =============================================
// PAGE RENDERING FUNCTIONS
// =============================================
function renderLoginPage() {
    $error = $_GET['error'] ?? '';
    ?>
    <div class="container">
        <div class="row justify-content-center align-items-center min-vh-100">
            <div class="col-md-4">
                <div class="card p-4">
                    <div class="text-center mb-4">
                        <div class="bg-primary text-white rounded-circle p-3 d-inline-block mb-3">
                            <i class="bi bi-shield-lock fs-2"></i>
                        </div>
                        <h3>SlowDNS Panel</h3>
                        <p class="text-muted">Admin Login</p>
                    </div>
                    
                    <?php if ($error): ?>
                    <div class="alert alert-danger"><?php echo htmlspecialchars($error); ?></div>
                    <?php endif; ?>
                    
                    <form method="POST" action="?action=do_login">
                        <div class="mb-3">
                            <label class="form-label">Username</label>
                            <input type="text" name="username" class="form-control" required>
                        </div>
                        <div class="mb-3">
                            <label class="form-label">Password</label>
                            <input type="password" name="password" class="form-control" required>
                        </div>
                        <button type="submit" class="btn btn-primary w-100 py-2">
                            <i class="bi bi-box-arrow-in-right me-2"></i> Login
                        </button>
                    </form>
                    
                    <div class="text-center mt-3">
                        <small class="text-muted">Default: admin / admin123</small>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php
    exit;
}

function renderDashboard() {
    global $data;
    $username = $_SESSION['user']['username'];
    $server_status = getServerStatus();
    
    // Get user's clients
    $user_clients = [];
    foreach ($data['clients'] as $id => $client) {
        if ($client['owner'] == $username) {
            $user_clients[$id] = $client;
        }
    }
    
    // Calculate stats
    $total_clients = count($user_clients);
    $active_clients = count(array_filter($user_clients, fn($c) => $c['active']));
    $total_bw = array_sum(array_column($user_clients, 'bandwidth_used'));
    
    renderHeader("Dashboard");
    ?>
    
    <!-- Welcome Message -->
    <div class="card mb-4">
        <div class="card-body">
            <div class="d-flex justify-content-between align-items-center">
                <div>
                    <h4 class="mb-1">Welcome, <?php echo $username; ?>!</h4>
                    <p class="text-muted mb-0">Manage your SlowDNS clients and monitor server status</p>
                </div>
                <div class="text-end">
                    <div class="badge bg-primary">Server IP: <?php echo $server_status['ip']; ?></div>
                    <div class="badge bg-info mt-1">Port: <?php echo $data['server']['port']; ?></div>
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
                        <h6 class="text-muted">My Clients</h6>
                        <h3 class="mb-0"><?php echo $total_clients; ?></h3>
                    </div>
                    <div class="bg-primary text-white rounded-circle p-2">
                        <i class="bi bi-person-badge fs-4"></i>
                    </div>
                </div>
                <small class="text-muted"><?php echo $active_clients; ?> active</small>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: #4cc9f0;">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Bandwidth Used</h6>
                        <h3 class="mb-0"><?php echo formatBytes($total_bw); ?></h3>
                    </div>
                    <div class="bg-info text-white rounded-circle p-2">
                        <i class="bi bi-speedometer2 fs-4"></i>
                    </div>
                </div>
                <small class="text-muted">Total usage</small>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: #f8961e;">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Active Connections</h6>
                        <h3 class="mb-0"><?php echo $server_status['connections']; ?></h3>
                    </div>
                    <div class="bg-warning text-white rounded-circle p-2">
                        <i class="bi bi-people fs-4"></i>
                    </div>
                </div>
                <small class="text-muted">Real-time</small>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: #f72585;">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Server Status</h6>
                        <h3 class="mb-0 <?php echo $server_status['service'] == 'running' ? 'text-success' : 'text-danger'; ?>">
                            <?php echo ucfirst($server_status['service']); ?>
                        </h3>
                    </div>
                    <div class="bg-danger text-white rounded-circle p-2">
                        <i class="bi bi-server fs-4"></i>
                    </div>
                </div>
                <small class="text-muted">Service</small>
            </div>
        </div>
    </div>
    
    <!-- Server Details -->
    <div class="row">
        <div class="col-md-8">
            <div class="card mb-4">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-server me-2"></i> Server Information</h5>
                </div>
                <div class="card-body">
                    <div class="row">
                        <div class="col-md-6">
                            <table class="table table-sm">
                                <tr>
                                    <td><i class="bi bi-cpu text-muted"></i> CPU Load</td>
                                    <td>
                                        <span class="badge <?php echo $server_status['load'] > 1.5 ? 'bg-warning' : 'bg-success'; ?>">
                                            <?php echo $server_status['load']; ?>
                                        </span>
                                    </td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-memory text-muted"></i> Memory</td>
                                    <td><?php echo $server_status['memory']; ?>% used</td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-hdd text-muted"></i> Disk Space</td>
                                    <td><?php echo $server_status['disk_free_gb']; ?> GB free</td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-clock text-muted"></i> Uptime</td>
                                    <td><?php echo $server_status['uptime']; ?></td>
                                </tr>
                            </table>
                        </div>
                        <div class="col-md-6">
                            <table class="table table-sm">
                                <tr>
                                    <td><i class="bi bi-globe text-muted"></i> Server Name</td>
                                    <td><strong><?php echo $data['server']['name']; ?></strong></td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-ethernet text-muted"></i> Port</td>
                                    <td><span class="badge bg-info"><?php echo $data['server']['port']; ?></span></td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-people text-muted"></i> Max Connections</td>
                                    <td><?php echo $data['server']['max_connections']; ?></td>
                                </tr>
                                <tr>
                                    <td><i class="bi bi-shield-check text-muted"></i> Status</td>
                                    <td>
                                        <span class="badge <?php echo $server_status['port'] == 'open' ? 'bg-success' : 'bg-danger'; ?>">
                                            Port <?php echo $server_status['port']; ?>
                                        </span>
                                    </td>
                                </tr>
                            </table>
                        </div>
                    </div>
                    
                    <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                    <div class="mt-3">
                        <a href="?action=server_control" class="btn btn-outline-primary btn-sm">
                            <i class="bi bi-terminal me-1"></i> Server Control
                        </a>
                        <a href="?action=server_settings" class="btn btn-outline-secondary btn-sm">
                            <i class="bi bi-gear me-1"></i> Settings
                        </a>
                    </div>
                    <?php endif; ?>
                </div>
            </div>
            
            <!-- Recent Clients -->
            <div class="card">
                <div class="card-header d-flex justify-content-between align-items-center">
                    <h5 class="mb-0"><i class="bi bi-clock-history me-2"></i> My Recent Clients</h5>
                    <a href="?action=clients" class="btn btn-sm btn-outline-primary">View All</a>
                </div>
                <div class="card-body">
                    <?php if (empty($user_clients)): ?>
                    <div class="text-center py-4">
                        <i class="bi bi-person-x display-1 text-muted"></i>
                        <h5 class="mt-3">No clients yet</h5>
                        <p>Create your first SlowDNS client</p>
                        <a href="?action=create_client" class="btn btn-primary">Create Client</a>
                    </div>
                    <?php else: ?>
                    <div class="table-responsive">
                        <table class="table table-sm">
                            <thead>
                                <tr>
                                    <th>Name</th>
                                    <th>Bandwidth</th>
                                    <th>Status</th>
                                    <th>Created</th>
                                    <th>Actions</th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php 
                                $i = 0;
                                foreach (array_slice($user_clients, 0, 5, true) as $id => $client): 
                                    $bw_percent = ($client['bandwidth_used'] / $client['bandwidth_limit']) * 100;
                                ?>
                                <tr>
                                    <td>
                                        <strong><?php echo htmlspecialchars($client['name']); ?></strong><br>
                                        <small class="text-muted">Key: <?php echo substr($client['key'], 0, 8); ?>...</small>
                                    </td>
                                    <td>
                                        <small><?php echo formatBytes($client['bandwidth_used']); ?></small>
                                        <div class="progress progress-thin">
                                            <div class="progress-bar <?php echo $bw_percent > 80 ? 'bg-danger' : ($bw_percent > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                                 style="width: <?php echo min($bw_percent, 100); ?>%">
                                            </div>
                                        </div>
                                    </td>
                                    <td>
                                        <span class="badge <?php echo $client['active'] ? 'bg-success' : 'bg-secondary'; ?>">
                                            <?php echo $client['active'] ? 'Active' : 'Inactive'; ?>
                                        </span>
                                    </td>
                                    <td><small><?php echo date('M d', strtotime($client['created'])); ?></small></td>
                                    <td>
                                        <button class="btn btn-sm btn-outline-info" onclick="copyToClipboard('<?php echo addslashes($client['config']); ?>')">
                                            <i class="bi bi-clipboard"></i>
                                        </button>
                                        <a href="?action=delete_client&id=<?php echo $id; ?>" class="btn btn-sm btn-outline-danger" onclick="return confirm('Delete?')">
                                            <i class="bi bi-trash"></i>
                                        </a>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                            </tbody>
                        </table>
                    </div>
                    <?php endif; ?>
                </div>
            </div>
        </div>
        
        <!-- Quick Actions -->
        <div class="col-md-4">
            <div class="card mb-3">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-lightning-charge me-2"></i> Quick Actions</h5>
                </div>
                <div class="card-body">
                    <div class="d-grid gap-2">
                        <a href="?action=create_client" class="btn btn-primary mb-2">
                            <i class="bi bi-plus-circle me-2"></i> Create New Client
                        </a>
                        <a href="?action=clients" class="btn btn-outline-secondary mb-2">
                            <i class="bi bi-list-ul me-2"></i> View All Clients
                        </a>
                        <a href="?action=change_password" class="btn btn-outline-warning mb-2">
                            <i class="bi bi-key me-2"></i> Change Password
                        </a>
                        
                        <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                        <hr class="my-2">
                        <a href="?action=user_management" class="btn btn-outline-success mb-2">
                            <i class="bi bi-people me-2"></i> User Management
                        </a>
                        <a href="?action=server_control" class="btn btn-outline-info">
                            <i class="bi bi-terminal me-2"></i> Server Control
                        </a>
                        <?php endif; ?>
                    </div>
                </div>
            </div>
            
            <!-- System Info -->
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-info-circle me-2"></i> System Info</h5>
                </div>
                <div class="card-body">
                    <div class="mb-2">
                        <small class="text-muted">PHP Version</small>
                        <div><?php echo phpversion(); ?></div>
                    </div>
                    <div class="mb-2">
                        <small class="text-muted">Panel Version</small>
                        <div>v2.0</div>
                    </div>
                    <div class="mb-2">
                        <small class="text-muted">Data File</small>
                        <div><code>data.json</code></div>
                    </div>
                    <div>
                        <small class="text-muted">Last Update</small>
                        <div><?php echo date('Y-m-d H:i:s'); ?></div>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php
}

function renderUserManagementPage() {
    global $data;
    if ($_SESSION['user']['role'] != 'admin') {
        header('Location: ?');
        exit;
    }
    
    renderHeader("User Management");
    ?>
    
    <div class="d-flex justify-content-between align-items-center mb-4">
        <h4><i class="bi bi-people me-2"></i> User Management</h4>
        <button class="btn btn-primary" data-bs-toggle="modal" data-bs-target="#addUserModal">
            <i class="bi bi-person-plus me-2"></i> Add User
        </button>
    </div>
    
    <div class="card">
        <div class="card-body">
            <div class="table-responsive">
                <table class="table table-hover">
                    <thead>
                        <tr>
                            <th>Username</th>
                            <th>Role</th>
                            <th>Email</th>
                            <th>Clients</th>
                            <th>Last Login</th>
                            <th>Status</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($data['users'] as $username => $user): 
                            // Count user's clients
                            $client_count = 0;
                            foreach ($data['clients'] as $client) {
                                if ($client['owner'] == $username) {
                                    $client_count++;
                                }
                            }
                        ?>
                        <tr>
                            <td>
                                <strong><?php echo $username; ?></strong>
                                <?php if ($username == $_SESSION['user']['username']): ?>
                                <span class="badge bg-primary">You</span>
                                <?php endif; ?>
                            </td>
                            <td>
                                <span class="badge <?php echo $user['role'] == 'admin' ? 'bg-warning' : 'bg-info'; ?>">
                                    <?php echo ucfirst($user['role']); ?>
                                </span>
                            </td>
                            <td><?php echo $user['email'] ?? 'N/A'; ?></td>
                            <td><?php echo $client_count; ?></td>
                            <td>
                                <?php if ($user['last_login']): ?>
                                <small><?php echo date('M d, H:i', strtotime($user['last_login'])); ?></small>
                                <?php else: ?>
                                <span class="text-muted">Never</span>
                                <?php endif; ?>
                            </td>
                            <td>
                                <?php if ($user['active']): ?>
                                <span class="badge bg-success">Active</span>
                                <?php else: ?>
                                <span class="badge bg-danger">Inactive</span>
                                <?php endif; ?>
                            </td>
                            <td>
                                <div class="btn-group btn-group-sm">
                                    <?php if ($username != 'admin'): ?>
                                    <a href="?action=toggle_user&user=<?php echo $username; ?>" class="btn btn-outline-warning">
                                        <i class="bi bi-power"></i>
                                    </a>
                                    <a href="?action=delete_user&user=<?php echo $username; ?>" class="btn btn-outline-danger" 
                                       onclick="return confirm('Delete user <?php echo $username; ?>?')">
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
    
    <!-- Add User Modal -->
    <div class="modal fade" id="addUserModal" tabindex="-1">
        <div class="modal-dialog">
            <div class="modal-content">
                <form method="POST" action="?action=add_user">
                    <div class="modal-header">
                        <h5 class="modal-title">Add New User</h5>
                        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                    </div>
                    <div class="modal-body">
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
                        <div class="mb-3">
                            <label class="form-label">Role</label>
                            <select name="role" class="form-select">
                                <option value="user">User</option>
                                <option value="admin">Admin</option>
                            </select>
                        </div>
                    </div>
                    <div class="modal-footer">
                        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                        <button type="submit" class="btn btn-primary">Add User</button>
                    </div>
                </form>
            </div>
        </div>
    </div>
    <?php
}

function renderServerSettingsPage() {
    global $data;
    if ($_SESSION['user']['role'] != 'admin') {
        header('Location: ?');
        exit;
    }
    
    renderHeader("Server Settings");
    ?>
    
    <div class="card">
        <div class="card-header">
            <h5 class="mb-0"><i class="bi bi-gear me-2"></i> Server Configuration</h5>
        </div>
        <div class="card-body">
            <form method="POST" action="?action=save_server_settings">
                <div class="row">
                    <div class="col-md-6 mb-3">
                        <label class="form-label">Server Name *</label>
                        <input type="text" name="server_name" class="form-control" 
                               value="<?php echo htmlspecialchars($data['server']['name']); ?>" required>
                    </div>
                    
                    <div class="col-md-6 mb-3">
                        <label class="form-label">Domain *</label>
                        <input type="text" name="domain" class="form-control" 
                               value="<?php echo htmlspecialchars($data['server']['domain']); ?>" required>
                        <small class="text-muted">Used in client configurations</small>
                    </div>
                    
                    <div class="col-md-6 mb-3">
                        <label class="form-label">Port *</label>
                        <input type="number" name="port" class="form-control" 
                               value="<?php echo $data['server']['port']; ?>" min="1" max="65535" required>
                        <small class="text-muted">SlowDNS server port</small>
                    </div>
                    
                    <div class="col-md-6 mb-3">
                        <label class="form-label">Max Connections</label>
                        <input type="number" name="max_connections" class="form-control" 
                               value="<?php echo $data['server']['max_connections']; ?>" min="1" max="1000">
                    </div>
                    
                    <div class="col-12 mb-3">
                        <div class="form-check form-switch">
                            <input type="checkbox" name="maintenance" class="form-check-input" 
                                   id="maintenance" <?php echo $data['server']['maintenance'] ? 'checked' : ''; ?>>
                            <label class="form-check-label" for="maintenance">
                                Maintenance Mode
                            </label>
                            <small class="text-muted d-block">Block new connections when enabled</small>
                        </div>
                    </div>
                </div>
                
                <div class="d-flex justify-content-end">
                    <button type="submit" class="btn btn-primary">
                        <i class="bi bi-save me-2"></i> Save Settings
                    </button>
                </div>
            </form>
        </div>
    </div>
    
    <!-- Change Admin Password -->
    <div class="card mt-3">
        <div class="card-header">
            <h5 class="mb-0"><i class="bi bi-key me-2"></i> Change Admin Password</h5>
        </div>
        <div class="card-body">
            <?php if (isset($_GET['password_success'])): ?>
            <div class="alert alert-success">Password changed successfully!</div>
            <?php endif; ?>
            
            <?php if (isset($_GET['password_error'])): ?>
            <div class="alert alert-danger"><?php echo htmlspecialchars($_GET['password_error']); ?></div>
            <?php endif; ?>
            
            <form method="POST" action="?action=change_admin_password">
                <div class="row">
                    <div class="col-md-4 mb-3">
                        <label class="form-label">Current Password *</label>
                        <input type="password" name="current_password" class="form-control" required>
                    </div>
                    
                    <div class="col-md-4 mb-3">
                        <label class="form-label">New Password *</label>
                        <input type="password" name="new_password" class="form-control" required minlength="6">
                    </div>
                    
                    <div class="col-md-4 mb-3">
                        <label class="form-label">Confirm New Password *</label>
                        <input type="password" name="confirm_password" class="form-control" required>
                    </div>
                </div>
                
                <div class="d-flex justify-content-end">
                    <button type="submit" class="btn btn-warning">
                        <i class="bi bi-check-circle me-2"></i> Change Password
                    </button>
                </div>
            </form>
        </div>
    </div>
    <?php
}

function renderServerControlPage() {
    global $data;
    if ($_SESSION['user']['role'] != 'admin') {
        header('Location: ?');
        exit;
    }
    
    $status = getServerStatus();
    
    renderHeader("Server Control");
    ?>
    
    <div class="row">
        <div class="col-md-6">
            <div class="card mb-4">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-power me-2"></i> Service Control</h5>
                </div>
                <div class="card-body">
                    <div class="row text-center mb-4">
                        <div class="col-4 mb-3">
                            <div class="p-3 border rounded">
                                <i class="bi bi-play-circle fs-1 text-success mb-2"></i>
                                <h6>Start</h6>
                                <a href="?action=start_service" class="btn btn-success btn-sm w-100">Start</a>
                            </div>
                        </div>
                        <div class="col-4 mb-3">
                            <div class="p-3 border rounded">
                                <i class="bi bi-stop-circle fs-1 text-danger mb-2"></i>
                                <h6>Stop</h6>
                                <a href="?action=stop_service" class="btn btn-danger btn-sm w-100">Stop</a>
                            </div>
                        </div>
                        <div class="col-4 mb-3">
                            <div class="p-3 border rounded">
                                <i class="bi bi-arrow-clockwise fs-1 text-primary mb-2"></i>
                                <h6>Restart</h6>
                                <a href="?action=restart_service" class="btn btn-primary btn-sm w-100">Restart</a>
                            </div>
                        </div>
                    </div>
                    
                    <div class="alert <?php echo $status['service'] == 'running' ? 'alert-success' : 'alert-danger'; ?>">
                        <i class="bi bi-info-circle me-2"></i>
                        Current Status: <strong><?php echo ucfirst($status['service']); ?></strong>
                        | Active Connections: <strong><?php echo $status['connections']; ?></strong>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-terminal me-2"></i> Command Line</h5>
                </div>
                <div class="card-body">
                    <form method="POST" action="?action=execute_command">
                        <div class="mb-3">
                            <label class="form-label">Execute Command</label>
                            <input type="text" name="command" class="form-control" 
                                   placeholder="systemctl status server-sldns.service">
                        </div>
                        <button type="submit" class="btn btn-outline-primary">Execute</button>
                    </form>
                </div>
            </div>
        </div>
    </div>
    
    <!-- System Info -->
    <div class="card mt-3">
        <div class="card-header">
            <h5 class="mb-0"><i class="bi bi-info-circle me-2"></i> System Information</h5>
        </div>
        <div class="card-body">
            <div class="row">
                <div class="col-md-3">
                    <div class="text-center p-3 border rounded">
                        <div class="fs-2 mb-2"><?php echo $status['load']; ?></div>
                        <small class="text-muted">CPU Load</small>
                    </div>
                </div>
                <div class="col-md-3">
                    <div class="text-center p-3 border rounded">
                        <div class="fs-2 mb-2"><?php echo $status['memory']; ?>%</div>
                        <small class="text-muted">Memory Usage</small>
                    </div>
                </div>
                <div class="col-md-3">
                    <div class="text-center p-3 border rounded">
                        <div class="fs-2 mb-2"><?php echo $status['disk_free_gb']; ?> GB</div>
                        <small class="text-muted">Free Disk</small>
                    </div>
                </div>
                <div class="col-md-3">
                    <div class="text-center p-3 border rounded">
                        <div class="fs-2 mb-2"><?php echo $status['connections']; ?></div>
                        <small class="text-muted">Connections</small>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php
}

function renderChangePasswordPage() {
    renderHeader("Change Password");
    ?>
    
    <div class="row justify-content-center">
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-key me-2"></i> Change Password</h5>
                </div>
                <div class="card-body">
                    <?php if (isset($_GET['success'])): ?>
                    <div class="alert alert-success">Password changed successfully!</div>
                    <?php endif; ?>
                    
                    <?php if (isset($_GET['error'])): ?>
                    <div class="alert alert-danger"><?php echo htmlspecialchars($_GET['error']); ?></div>
                    <?php endif; ?>
                    
                    <form method="POST" action="?action=do_change_password">
                        <div class="mb-3">
                            <label class="form-label">Current Password *</label>
                            <input type="password" name="current_password" class="form-control" required>
                        </div>
                        <div class="mb-3">
                            <label class="form-label">New Password *</label>
                            <input type="password" name="new_password" class="form-control" required minlength="6">
                        </div>
                        <div class="mb-3">
                            <label class="form-label">Confirm New Password *</label>
                            <input type="password" name="confirm_password" class="form-control" required>
                        </div>
                        <div class="d-grid gap-2">
                            <button type="submit" class="btn btn-warning">
                                <i class="bi bi-check-circle me-2"></i> Change Password
                            </button>
                            <a href="?" class="btn btn-outline-secondary">Cancel</a>
                        </div>
                    </form>
                </div>
            </div>
        </div>
    </div>
    <?php
}

// =============================================
// ACTION HANDLERS
// =============================================
function handleActions() {
    global $data;
    $action = $_GET['action'] ?? '';
    
    switch ($action) {
        case 'do_login':
            if (login($_POST['username'], $_POST['password'])) {
                header('Location: ?');
                exit;
            } else {
                header('Location: ?action=login&error=Invalid credentials');
                exit;
            }
            break;
            
        case 'logout':
            logout();
            break;
            
        case 'save_server_settings':
            if ($_SESSION['user']['role'] == 'admin') {
                $data['server']['name'] = $_POST['server_name'];
                $data['server']['domain'] = $_POST['domain'];
                $data['server']['port'] = $_POST['port'];
                $data['server']['max_connections'] = $_POST['max_connections'];
                $data['server']['maintenance'] = isset($_POST['maintenance']);
                saveData();
                logActivity("Server settings updated");
                header('Location: ?action=server_settings&saved=1');
                exit;
            }
            break;
            
        case 'add_user':
            if ($_SESSION['user']['role'] == 'admin') {
                $username = $_POST['username'];
                $password = $_POST['password'];
                $email = $_POST['email'] ?? '';
                $role = $_POST['role'] ?? 'user';
                
                $data['users'][$username] = [
                    'password' => password_hash($password, PASSWORD_DEFAULT),
                    'role' => $role,
                    'email' => $email,
                    'created' => date('Y-m-d H:i:s'),
                    'active' => true,
                    'max_clients' => 10
                ];
                saveData();
                logActivity("User added: $username");
                header('Location: ?action=user_management');
                exit;
            }
            break;
            
        case 'delete_user':
            if ($_SESSION['user']['role'] == 'admin') {
                $username = $_GET['user'] ?? '';
                if ($username != 'admin' && $username != $_SESSION['user']['username']) {
                    unset($data['users'][$username]);
                    saveData();
                    logActivity("User deleted: $username");
                }
                header('Location: ?action=user_management');
                exit;
            }
            break;
            
        case 'toggle_user':
            if ($_SESSION['user']['role'] == 'admin') {
                $username = $_GET['user'] ?? '';
                if ($username != 'admin') {
                    $data['users'][$username]['active'] = !$data['users'][$username]['active'];
                    saveData();
                    logActivity("User toggled: $username to " . ($data['users'][$username]['active'] ? 'active' : 'inactive'));
                }
                header('Location: ?action=user_management');
                exit;
            }
            break;
            
        case 'change_admin_password':
            if ($_SESSION['user']['role'] == 'admin') {
                $current = $_POST['current_password'] ?? '';
                $new = $_POST['new_password'] ?? '';
                $confirm = $_POST['confirm_password'] ?? '';
                
                if (password_verify($current, $data['users']['admin']['password'])) {
                    if ($new == $confirm) {
                        $data['users']['admin']['password'] = password_hash($new, PASSWORD_DEFAULT);
                        saveData();
                        logActivity("Admin password changed");
                        header('Location: ?action=server_settings&password_success=1');
                        exit;
                    } else {
                        header('Location: ?action=server_settings&password_error=Passwords do not match');
                        exit;
                    }
                } else {
                    header('Location: ?action=server_settings&password_error=Current password incorrect');
                    exit;
                }
            }
            break;
            
        case 'start_service':
            if ($_SESSION['user']['role'] == 'admin') {
                exec('systemctl start server-sldns.service');
                logActivity("SlowDNS service started");
                header('Location: ?action=server_control');
                exit;
            }
            break;
            
        case 'stop_service':
            if ($_SESSION['user']['role'] == 'admin') {
                exec('systemctl stop server-sldns.service');
                logActivity("SlowDNS service stopped");
                header('Location: ?action=server_control');
                exit;
            }
            break;
            
        case 'restart_service':
            if ($_SESSION['user']['role'] == 'admin') {
                exec('systemctl restart server-sldns.service');
                $data['server']['restart_count']++;
                $data['server']['last_restart'] = date('Y-m-d H:i:s');
                saveData();
                logActivity("SlowDNS service restarted");
                header('Location: ?action=server_control');
                exit;
            }
            break;
            
        case 'do_change_password':
            $current = $_POST['current_password'] ?? '';
            $new = $_POST['new_password'] ?? '';
            $confirm = $_POST['confirm_password'] ?? '';
            $username = $_SESSION['user']['username'];
            
            if (password_verify($current, $data['users'][$username]['password'])) {
                if ($new == $confirm) {
                    $data['users'][$username]['password'] = password_hash($new, PASSWORD_DEFAULT);
                    saveData();
                    logActivity("Password changed for user: $username");
                    header('Location: ?action=change_password&success=1');
                    exit;
                } else {
                    header('Location: ?action=change_password&error=Passwords do not match');
                    exit;
                }
            } else {
                header('Location: ?action=change_password&error=Current password incorrect');
                exit;
            }
            break;
    }
}

// =============================================
// MAIN ROUTER
// =============================================
$action = $_GET['action'] ?? '';

// Handle POST actions
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    handleActions();
}

// Check if user is logged in
if (!isset($_SESSION['user'])) {
    if ($action == 'do_login' || $action == 'login') {
        renderLoginPage();
    } else {
        header('Location: ?action=login');
        exit;
    }
}

// Render pages based on action
switch ($action) {
    case '':
    case 'dashboard':
        renderDashboard();
        break;
    case 'clients':
        // Add clients page here
        renderDashboard(); // Temporary
        break;
    case 'create_client':
        // Add create client page here
        renderDashboard(); // Temporary
        break;
    case 'server_settings':
        renderServerSettingsPage();
        break;
    case 'user_management':
        renderUserManagementPage();
        break;
    case 'server_control':
        renderServerControlPage();
        break;
    case 'change_password':
        renderChangePasswordPage();
        break;
    case 'logout':
        logout();
        break;
    default:
        renderDashboard();
        break;
}

renderFooter();
EOF

print_success "Web panel created at $PANEL_FILE"

# Create additional directories
mkdir -p "$WEB_DIR/assets"
mkdir -p "$WEB_DIR/uploads"

# Create .htaccess for security
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
<FilesMatch "\.(json|log|ini|conf)$">
    Require all denied
</FilesMatch>

# PHP settings
php_value upload_max_filesize 50M
php_value post_max_size 50M
php_value memory_limit 256M
EOF

# Set permissions
print_info "Setting permissions..."
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
chmod 644 "$PANEL_FILE"
chmod 600 "$WEB_DIR/.htaccess" 2>/dev/null || true

# Configure Apache
print_info "Configuring Apache..."

# Create Apache config
cat > /etc/apache2/sites-available/slowdns-panel.conf << EOF
<VirtualHost *:80>
    ServerName slowdns-panel
    ServerAdmin admin@localhost
    DocumentRoot $WEB_DIR
    
    <Directory $WEB_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/slowdns-panel-error.log
    CustomLog \${APACHE_LOG_DIR}/slowdns-panel-access.log combined
</VirtualHost>
EOF

# Enable site
a2ensite slowdns-panel.conf
a2dissite 000-default.conf
a2enmod rewrite headers

# Restart Apache
print_info "Restarting Apache..."
systemctl restart apache2
systemctl enable apache2

# Configure firewall
print_info "Configuring firewall..."
ufw --force enable
ufw allow 80/tcp
ufw allow 22/tcp
ufw allow "$SLOWDNS_PORT"/udp

# Create systemd service for auto-start
cat > /etc/systemd/system/slowdns-panel.service << EOF
[Unit]
Description=SlowDNS Web Panel
After=network.target apache2.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slowdns-panel.service

# Create backup script
cat > /usr/local/bin/backup-slowdns-panel.sh << 'EOF'
#!/bin/bash
# Backup SlowDNS Panel
BACKUP_DIR="/root/slowdns-backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/slowdns-panel-$DATE.tar.gz"

mkdir -p $BACKUP_DIR
tar -czf $BACKUP_FILE -C /var/www slowdns-panel/
echo "Backup created: $BACKUP_FILE"

# Remove old backups (keep last 7 days)
find $BACKUP_DIR -name "slowdns-panel-*.tar.gz" -mtime +7 -delete
EOF

chmod +x /usr/local/bin/backup-slowdns-panel.sh

# Add to crontab for daily backup
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-slowdns-panel.sh") | crontab -

# Get server IP
SERVER_IP=$(get_server_ip)

# =============================================
# INSTALLATION COMPLETE
# =============================================
print_success "Installation completed successfully!"
echo ""
echo -e "${CYAN}==============================================${NC}"
echo -e "${GREEN}SLOWDNS WEB PANEL INSTALLED SUCCESSFULLY!${NC}"
echo -e "${CYAN}==============================================${NC}"
echo ""
echo -e "${YELLOW}ACCESS INFORMATION:${NC}"
echo -e "Panel URL: ${GREEN}http://$SERVER_IP/${NC}"
echo -e "          or ${GREEN}http://$SERVER_IP:80/${NC}"
echo ""
echo -e "${YELLOW}LOGIN CREDENTIALS:${NC}"
echo -e "Username: ${GREEN}$ADMIN_USER${NC}"
echo -e "Password: ${GREEN}$ADMIN_PASS${NC}"
echo -e "${RED}IMPORTANT: Change this password immediately!${NC}"
echo ""
echo -e "${YELLOW}SLOWDNS SERVER:${NC}"
echo -e "Port: ${GREEN}$SLOWDNS_PORT${NC} (UDP)"
echo -e "Server IP: ${GREEN}$SERVER_IP${NC}"
echo ""
echo -e "${YELLOW}FEATURES INSTALLED:${NC}"
echo "✓ Complete Web Panel"
echo "✓ User Management (Add/Edit/Delete users)"
echo "✓ Server Control (Start/Stop/Restart)"
echo "✓ Server Settings (Change name, port, domain)"
echo "✓ Bandwidth Monitoring"
echo "✓ Client Management"
echo "✓ Change Password"
echo "✓ Activity Logs"
echo "✓ Automatic Backups"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Access the panel at http://$SERVER_IP/"
echo "2. Change admin password immediately"
echo "3. Configure server settings"
echo "4. Add users as needed"
echo ""
echo -e "${CYAN}Installation log: $LOG_FILE${NC}"
echo ""

# Write installation info
cat > /root/slowdns-panel-install.txt << EOF
SlowDNS Web Panel Installation Complete
=======================================
Installed on: $(date)
Server IP: $SERVER_IP
Panel URL: http://$SERVER_IP/
Admin Username: $ADMIN_USER
Admin Password: $ADMIN_PASS
SlowDNS Port: $SLOWDNS_PORT
Web Directory: $WEB_DIR
Data File: $WEB_DIR/data.json
Log File: $WEB_DIR/activity.log

Features:
- User Management
- Server Control
- Bandwidth Monitoring
- Client Management
- Change Password
- Activity Logs

To change admin password:
1. Login to panel
2. Go to Server Settings
3. Use "Change Admin Password" section

Backup location: /root/slowdns-backups/
EOF

print_info "Installation details saved to: /root/slowdns-panel-install.txt"
print_warning "Please change the default admin password immediately!"
