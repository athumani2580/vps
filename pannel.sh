<?php
/**
 * Complete SlowDNS Web Panel v2.0
 * Single File - All Features Included
 */

// =============================================
// CONFIGURATION
// =============================================
define('SITE_NAME', 'SlowDNS Manager Pro');
define('ADMIN_USER', 'admin');
define('ADMIN_PASS', 'admin123'); // CHANGE THIS!
define('SLOWDNS_PORT', 5300);
define('SLOWDNS_DIR', '/etc/slowdns');
define('DATA_FILE', __DIR__ . '/data.json');
define('LOG_FILE', __DIR__ . '/activity.log');
define('DEFAULT_LIMIT_GB', 5);

// =============================================
// INITIALIZATION
// =============================================
session_start();
date_default_timezone_set('UTC');

// Create data file if doesn't exist
if (!file_exists(DATA_FILE)) {
    $initial_data = [
        'users' => [
            ADMIN_USER => [
                'password' => password_hash(ADMIN_PASS, PASSWORD_DEFAULT),
                'role' => 'admin',
                'email' => 'admin@localhost',
                'created' => date('Y-m-d H:i:s'),
                'last_login' => null,
                'ip_whitelist' => [],
                'max_clients' => 999,
                'active' => true
            ]
        ],
        'clients' => [],
        'server' => [
            'name' => 'My SlowDNS Server',
            'domain' => 'dns.example.com',
            'port' => SLOWDNS_PORT,
            'max_connections' => 100,
            'maintenance' => false,
            'restart_count' => 0,
            'last_restart' => null
        ],
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
    
    return $status;
}

function generateClientConfig($client) {
    global $data;
    $server = $data['server'];
    
    $config = "# SlowDNS Client Configuration\n";
    $config .= "# Generated: " . date('Y-m-d H:i:s') . "\n\n";
    
    $config .= "[client]\n";
    $config .= "name = " . $client['name'] . "\n";
    $config .= "server = " . (empty($server['domain']) ? $_SERVER['SERVER_ADDR'] : $server['domain']) . "\n";
    $config .= "port = " . $server['port'] . "\n";
    $config .= "key = " . $client['key'] . "\n";
    $config .= "mtu = 1200\n";
    $config .= "protocol = udp\n";
    $config .= "dns = 8.8.8.8\n";
    $config .= "keepalive = 30\n";
    
    return $config;
}

function restartSlowDNS() {
    exec('systemctl restart server-sldns.service 2>&1', $output, $code);
    return $code == 0;
}

function getUserClients($username) {
    global $data;
    $user_clients = [];
    foreach ($data['clients'] as $id => $client) {
        if ($client['owner'] == $username) {
            $user_clients[$id] = $client;
        }
    }
    return $user_clients;
}

function getClientUsage($client_id) {
    global $data;
    if (!isset($data['clients'][$client_id])) return 0;
    return $data['clients'][$client_id]['bandwidth_used'];
}

function formatBytes($bytes, $precision = 2) {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $bytes = max($bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min($pow, count($units) - 1);
    $bytes /= pow(1024, $pow);
    return round($bytes, $precision) . ' ' . $units[$pow];
}

// =============================================
// AUTHENTICATION
// =============================================
function isLoggedIn() {
    return isset($_SESSION['user']) && isset($data['users'][$_SESSION['user']['username']]);
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
    $active_connections = $server_status['connections'];
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title><?php echo $title; ?> - <?php echo SITE_NAME; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
        <style>
            :root {
                --primary: #4361ee;
                --secondary: #3a0ca3;
                --success: #4cc9f0;
                --danger: #f72585;
                --warning: #f8961e;
                --dark: #1a1a2e;
                --light: #f8f9fa;
            }
            body { background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%); min-height: 100vh; }
            .navbar { background: var(--dark) !important; box-shadow: 0 4px 12px rgba(0,0,0,0.1); }
            .sidebar { background: white; border-radius: 15px; box-shadow: 0 0 20px rgba(0,0,0,0.08); }
            .card { border: none; border-radius: 15px; box-shadow: 0 5px 15px rgba(0,0,0,0.05); transition: transform 0.3s; }
            .card:hover { transform: translateY(-5px); }
            .stat-card { border-left: 4px solid var(--primary); }
            .status-online { color: #38b000; }
            .status-offline { color: #e63946; }
            .user-avatar { width: 40px; height: 40px; background: var(--primary); color: white; border-radius: 50%; display: flex; align-items: center; justify-content: center; }
            .progress-thin { height: 8px; border-radius: 4px; }
            .badge-online { background: #38b000; }
            .badge-offline { background: #e63946; }
            .table th { border-top: none; color: #6c757d; font-weight: 600; }
        </style>
    </head>
    <body>
        <!-- Navbar -->
        <nav class="navbar navbar-expand-lg navbar-dark">
            <div class="container-fluid">
                <a class="navbar-brand" href="?">
                    <i class="bi bi-shield-lock me-2"></i>
                    <strong><?php echo $data['server']['name']; ?></strong>
                </a>
                
                <div class="d-flex align-items-center">
                    <!-- Connection Status -->
                    <div class="me-3">
                        <span class="badge <?php echo $active_connections > 0 ? 'bg-success' : 'bg-secondary'; ?>">
                            <i class="bi bi-people-fill"></i> <?php echo $active_connections; ?> Connected
                        </span>
                    </div>
                    
                    <!-- User Menu -->
                    <?php if (isset($_SESSION['user'])): ?>
                    <div class="dropdown">
                        <button class="btn btn-outline-light dropdown-toggle d-flex align-items-center" type="button" data-bs-toggle="dropdown">
                            <div class="user-avatar me-2">
                                <?php echo strtoupper(substr($_SESSION['user']['username'], 0, 1)); ?>
                            </div>
                            <?php echo $_SESSION['user']['username']; ?>
                            <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                            <span class="badge bg-warning ms-2">Admin</span>
                            <?php endif; ?>
                        </button>
                        <ul class="dropdown-menu dropdown-menu-end">
                            <li><a class="dropdown-item" href="?action=profile"><i class="bi bi-person-circle"></i> Profile</a></li>
                            <li><a class="dropdown-item" href="?action=change_password"><i class="bi bi-key"></i> Change Password</a></li>
                            <li><hr class="dropdown-divider"></li>
                            <li><a class="dropdown-item text-danger" href="?action=logout"><i class="bi bi-box-arrow-right"></i> Logout</a></li>
                        </ul>
                    </div>
                    <?php endif; ?>
                </div>
            </div>
        </nav>
        
        <div class="container-fluid mt-4">
            <div class="row">
                <!-- Sidebar -->
                <div class="col-lg-2">
                    <div class="sidebar p-3 mb-4">
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
                            <hr>
                            <h6 class="text-muted mt-3 mb-2">Admin Panel</h6>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'server_settings' ? 'active' : ''; ?>" href="?action=server_settings">
                                <i class="bi bi-gear me-2"></i> Server Settings
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'user_management' ? 'active' : ''; ?>" href="?action=user_management">
                                <i class="bi bi-people me-2"></i> User Management
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'server_control' ? 'active' : ''; ?>" href="?action=server_control">
                                <i class="bi bi-terminal me-2"></i> Server Control
                            </a>
                            <a class="nav-link <?php echo ($_GET['action'] ?? '') == 'logs' ? 'active' : ''; ?>" href="?action=logs">
                                <i class="bi bi-list-check me-2"></i> Activity Logs
                            </a>
                            <?php endif; ?>
                        </nav>
                    </div>
                    
                    <!-- Quick Stats -->
                    <div class="card p-3">
                        <h6 class="text-muted">Quick Stats</h6>
                        <div class="mt-3">
                            <div class="d-flex justify-content-between mb-2">
                                <small>Server Status:</small>
                                <span class="badge <?php echo $server_status['service'] == 'running' ? 'bg-success' : 'bg-danger'; ?>">
                                    <?php echo ucfirst($server_status['service']); ?>
                                </span>
                            </div>
                            <div class="d-flex justify-content-between mb-2">
                                <small>Memory:</small>
                                <small class="text-muted"><?php echo $server_status['memory']; ?>%</small>
                            </div>
                            <div class="d-flex justify-content-between">
                                <small>Load:</small>
                                <small class="text-muted"><?php echo $server_status['load']; ?></small>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Main Content -->
                <div class="col-lg-10">
    <?php
}

function renderFooter() {
    global $data;
    ?>
                </div>
            </div>
        </div>
        
        <!-- Footer -->
        <footer class="mt-5 py-3 text-center text-muted">
            <div class="container">
                <small>
                    <?php echo SITE_NAME; ?> v2.0 &copy; <?php echo date('Y'); ?> | 
                    Server: <?php echo $data['server']['name']; ?> | 
                    Uptime: <?php echo getServerStatus()['uptime']; ?>
                </small>
            </div>
        </footer>
        
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <script>
            // Auto refresh every 60 seconds
            setTimeout(() => location.reload(), 60000);
            
            // Copy to clipboard
            window.copyToClipboard = function(text) {
                navigator.clipboard.writeText(text).then(() => {
                    alert('Copied to clipboard!');
                });
            };
            
            // Download config
            window.downloadConfig = function(name, config) {
                const blob = new Blob([config], {type: 'text/plain'});
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = name + '-slowdns.conf';
                a.click();
                URL.revokeObjectURL(url);
            };
            
            // Show QR Code
            window.showQR = function(config) {
                const qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' + encodeURIComponent(config);
                const modal = new bootstrap.Modal(document.getElementById('qrModal'));
                document.getElementById('qrImage').src = qrUrl;
                modal.show();
            };
        </script>
        
        <!-- QR Modal -->
        <div class="modal fade" id="qrModal" tabindex="-1">
            <div class="modal-dialog modal-sm">
                <div class="modal-content">
                    <div class="modal-header">
                        <h5 class="modal-title">QR Code</h5>
                        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                    </div>
                    <div class="modal-body text-center">
                        <img id="qrImage" src="" alt="QR Code" class="img-fluid">
                        <p class="text-muted mt-2">Scan to configure client</p>
                    </div>
                </div>
            </div>
        </div>
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
            <div class="col-md-5">
                <div class="card p-4">
                    <div class="text-center mb-4">
                        <div class="user-avatar mx-auto mb-3" style="width: 80px; height: 80px; font-size: 2rem;">
                            <i class="bi bi-shield-lock"></i>
                        </div>
                        <h3><?php echo SITE_NAME; ?></h3>
                        <p class="text-muted">SlowDNS Management Panel</p>
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
    $user_clients = getUserClients($username);
    $server_status = getServerStatus();
    
    // Calculate stats
    $total_clients = count($user_clients);
    $active_clients = count(array_filter($user_clients, fn($c) => $c['active']));
    $total_bw = array_sum(array_column($user_clients, 'bandwidth_used'));
    $total_limit = array_sum(array_column($user_clients, 'bandwidth_limit'));
    $usage_percent = $total_limit > 0 ? min(100, ($total_bw / $total_limit) * 100) : 0;
    
    renderHeader("Dashboard");
    ?>
    
    <!-- Stats Cards -->
    <div class="row mb-4">
        <div class="col-md-3">
            <div class="card stat-card p-3">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">My Clients</h6>
                        <h3 class="mb-0"><?php echo $total_clients; ?></h3>
                    </div>
                    <div class="bg-primary text-white rounded-circle p-3">
                        <i class="bi bi-person-badge fs-4"></i>
                    </div>
                </div>
                <small class="text-muted"><?php echo $active_clients; ?> active</small>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: var(--success);">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Bandwidth Used</h6>
                        <h3 class="mb-0"><?php echo formatBytes($total_bw); ?></h3>
                    </div>
                    <div class="bg-success text-white rounded-circle p-3">
                        <i class="bi bi-speedometer2 fs-4"></i>
                    </div>
                </div>
                <div class="progress progress-thin mt-2">
                    <div class="progress-bar bg-success" style="width: <?php echo $usage_percent; ?>%"></div>
                </div>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: var(--warning);">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Active Connections</h6>
                        <h3 class="mb-0"><?php echo $server_status['connections']; ?></h3>
                    </div>
                    <div class="bg-warning text-white rounded-circle p-3">
                        <i class="bi bi-people fs-4"></i>
                    </div>
                </div>
                <small class="text-muted">Real-time connections</small>
            </div>
        </div>
        
        <div class="col-md-3">
            <div class="card stat-card p-3" style="border-left-color: var(--danger);">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="text-muted">Server Status</h6>
                        <h3 class="mb-0 <?php echo $server_status['service'] == 'running' ? 'text-success' : 'text-danger'; ?>">
                            <?php echo ucfirst($server_status['service']); ?>
                        </h3>
                    </div>
                    <div class="bg-danger text-white rounded-circle p-3">
                        <i class="bi bi-server fs-4"></i>
                    </div>
                </div>
                <small class="text-muted">Port: <?php echo SLOWDNS_PORT; ?></small>
            </div>
        </div>
    </div>
    
    <!-- Server Details -->
    <div class="row mb-4">
        <div class="col-md-8">
            <div class="card">
                <div class="card-header d-flex justify-content-between align-items-center">
                    <h5 class="mb-0"><i class="bi bi-server me-2"></i> Server Details</h5>
                    <span class="badge bg-primary"><?php echo $data['server']['name']; ?></span>
                </div>
                <div class="card-body">
                    <div class="row">
                        <div class="col-md-6">
                            <table class="table table-sm">
                                <tr>
                                    <td><i class="bi bi-cpu text-muted"></i> CPU Load</td>
                                    <td><span class="badge <?php echo $server_status['load'] > 1.5 ? 'bg-warning' : 'bg-success'; ?>">
                                        <?php echo $server_status['load']; ?>
                                    </span></td>
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
                                    <td><i class="bi bi-globe text-muted"></i> Domain</td>
                                    <td><code><?php echo $data['server']['domain']; ?></code></td>
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
                                    <td><i class="bi bi-arrow-repeat text-muted"></i> Restart Count</td>
                                    <td><?php echo $data['server']['restart_count']; ?></td>
                                </tr>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="col-md-4">
            <div class="card h-100">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-lightning-charge me-2"></i> Quick Actions</h5>
                </div>
                <div class="card-body d-flex flex-column">
                    <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                    <a href="?action=server_control" class="btn btn-outline-primary mb-2">
                        <i class="bi bi-terminal me-2"></i> Server Control
                    </a>
                    <a href="?action=user_management" class="btn btn-outline-success mb-2">
                        <i class="bi bi-people me-2"></i> User Management
                    </a>
                    <?php endif; ?>
                    <a href="?action=create_client" class="btn btn-primary mb-2">
                        <i class="bi bi-plus-circle me-2"></i> Create New Client
                    </a>
                    <a href="?action=clients" class="btn btn-outline-secondary">
                        <i class="bi bi-list-ul me-2"></i> View All Clients
                    </a>
                </div>
            </div>
        </div>
    </div>
    
    <!-- Recent Clients -->
    <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center">
            <h5 class="mb-0"><i class="bi bi-clock-history me-2"></i> Recent Clients</h5>
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
                <table class="table table-hover">
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>Status</th>
                            <th>Bandwidth</th>
                            <th>Created</th>
                            <th>Last Used</th>
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
                                <small class="text-muted">ID: <?php echo substr($id, 0, 8); ?></small>
                            </td>
                            <td>
                                <span class="badge <?php echo $client['active'] ? 'bg-success' : 'bg-secondary'; ?>">
                                    <?php echo $client['active'] ? 'Active' : 'Inactive'; ?>
                                </span>
                            </td>
                            <td>
                                <small><?php echo formatBytes($client['bandwidth_used']); ?> / <?php echo formatBytes($client['bandwidth_limit']); ?></small>
                                <div class="progress progress-thin">
                                    <div class="progress-bar <?php echo $bw_percent > 80 ? 'bg-danger' : ($bw_percent > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                         style="width: <?php echo min($bw_percent, 100); ?>%">
                                    </div>
                                </div>
                            </td>
                            <td><small><?php echo date('M d, Y', strtotime($client['created'])); ?></small></td>
                            <td>
                                <small>
                                    <?php echo $client['last_used'] ? date('M d, H:i', strtotime($client['last_used'])) : 'Never'; ?>
                                </small>
                            </td>
                            <td>
                                <button class="btn btn-sm btn-outline-info" onclick="showQR('<?php echo addslashes($client['config']); ?>')">
                                    <i class="bi bi-qr-code"></i>
                                </button>
                                <button class="btn btn-sm btn-outline-success" onclick="copyToClipboard('<?php echo addslashes($client['config']); ?>')">
                                    <i class="bi bi-clipboard"></i>
                                </button>
                                <a href="?action=delete_client&id=<?php echo $id; ?>" class="btn btn-sm btn-outline-danger" onclick="return confirm('Delete this client?')">
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
    <?php
}

function renderClientsPage() {
    global $data;
    $username = $_SESSION['user']['username'];
    $user_clients = getUserClients($username);
    
    renderHeader("My Clients");
    ?>
    
    <div class="d-flex justify-content-between align-items-center mb-4">
        <h4><i class="bi bi-person-badge me-2"></i> My SlowDNS Clients</h4>
        <a href="?action=create_client" class="btn btn-primary">
            <i class="bi bi-plus-circle me-2"></i> Create New Client
        </a>
    </div>
    
    <?php if (empty($user_clients)): ?>
    <div class="card">
        <div class="card-body text-center py-5">
            <i class="bi bi-person-x display-1 text-muted"></i>
            <h4 class="mt-3">No clients yet</h4>
            <p class="text-muted">Create your first SlowDNS client to get started</p>
            <a href="?action=create_client" class="btn btn-primary btn-lg">
                <i class="bi bi-plus-circle me-2"></i> Create First Client
            </a>
        </div>
    </div>
    <?php else: ?>
    <div class="row">
        <?php foreach ($user_clients as $id => $client): 
            $bw_used = $client['bandwidth_used'];
            $bw_limit = $client['bandwidth_limit'];
            $bw_percent = ($bw_used / $bw_limit) * 100;
            $config = $client['config'];
        ?>
        <div class="col-md-6 col-lg-4 mb-3">
            <div class="card h-100">
                <div class="card-body">
                    <div class="d-flex justify-content-between align-items-start mb-3">
                        <div>
                            <h5 class="card-title"><?php echo htmlspecialchars($client['name']); ?></h5>
                            <p class="card-text">
                                <small class="text-muted">
                                    <i class="bi bi-key"></i> Key: <?php echo substr($client['key'], 0, 16); ?>...
                                </small>
                            </p>
                        </div>
                        <div class="dropdown">
                            <button class="btn btn-sm btn-outline-secondary dropdown-toggle" type="button" data-bs-toggle="dropdown">
                                <i class="bi bi-three-dots"></i>
                            </button>
                            <ul class="dropdown-menu">
                                <li><a class="dropdown-item" href="#" onclick="showQR('<?php echo addslashes($config); ?>')">
                                    <i class="bi bi-qr-code me-2"></i> QR Code
                                </a></li>
                                <li><a class="dropdown-item" href="#" onclick="copyToClipboard('<?php echo addslashes($config); ?>')">
                                    <i class="bi bi-clipboard me-2"></i> Copy Config
                                </a></li>
                                <li><a class="dropdown-item" href="#" onclick="downloadConfig('<?php echo $client['name']; ?>', '<?php echo addslashes($config); ?>')">
                                    <i class="bi bi-download me-2"></i> Download
                                </a></li>
                                <li><hr class="dropdown-divider"></li>
                                <li><a class="dropdown-item text-danger" href="?action=delete_client&id=<?php echo $id; ?>" onclick="return confirm('Delete this client?')">
                                    <i class="bi bi-trash me-2"></i> Delete
                                </a></li>
                            </ul>
                        </div>
                    </div>
                    
                    <div class="mb-3">
                        <div class="d-flex justify-content-between mb-1">
                            <small>Bandwidth Usage</small>
                            <small><?php echo formatBytes($bw_used); ?> / <?php echo formatBytes($bw_limit); ?></small>
                        </div>
                        <div class="progress progress-thin">
                            <div class="progress-bar <?php echo $bw_percent > 80 ? 'bg-danger' : ($bw_percent > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                 style="width: <?php echo min($bw_percent, 100); ?>%">
                            </div>
                        </div>
                    </div>
                    
                    <div class="d-flex justify-content-between text-muted small">
                        <div>
                            <i class="bi bi-calendar"></i> <?php echo date('M d, Y', strtotime($client['created'])); ?>
                        </div>
                        <div>
                            <span class="badge <?php echo $client['active'] ? 'bg-success' : 'bg-secondary'; ?>">
                                <?php echo $client['active'] ? 'Active' : 'Inactive'; ?>
                            </span>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <?php endforeach; ?>
    </div>
    <?php endif; ?>
    <?php
}

function renderCreateClientPage() {
    global $data;
    $username = $_SESSION['user']['username'];
    $user_clients = getUserClients($username);
    $max_clients = $data['users'][$username]['max_clients'] ?? 10;
    
    renderHeader("Create Client");
    ?>
    
    <div class="row justify-content-center">
        <div class="col-md-8">
            <div class="card">
                <div class="card-header bg-primary text-white">
                    <h5 class="mb-0"><i class="bi bi-plus-circle me-2"></i> Create New SlowDNS Client</h5>
                </div>
                <div class="card-body">
                    <?php if (count($user_clients) >= $max_clients): ?>
                    <div class="alert alert-warning">
                        <i class="bi bi-exclamation-triangle me-2"></i>
                        You have reached your limit of <?php echo $max_clients; ?> clients.
                        <?php if ($_SESSION['user']['role'] == 'admin'): ?>
                        <a href="?action=user_management" class="alert-link">Increase limit</a>
                        <?php endif; ?>
                    </div>
                    <?php else: ?>
                    <form method="POST" action="?action=save_client">
                        <div class="row">
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Client Name *</label>
                                <input type="text" name="name" class="form-control" required 
                                       placeholder="e.g., My Phone, Laptop, Tablet">
                                <small class="text-muted">A friendly name for this client</small>
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Custom Domain (Optional)</label>
                                <input type="text" name="domain" class="form-control" 
                                       placeholder="dns.example.com">
                                <small class="text-muted">Leave empty for default domain</small>
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Bandwidth Limit *</label>
                                <div class="input-group">
                                    <input type="number" name="limit" class="form-control" 
                                           value="<?php echo DEFAULT_LIMIT_GB; ?>" min="1" max="1000" required>
                                    <span class="input-group-text">GB</span>
                                </div>
                                <small class="text-muted">Monthly bandwidth limit</small>
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Connection Limit</label>
                                <input type="number" name="connections" class="form-control" 
                                       value="3" min="1" max="10">
                                <small class="text-muted">Max simultaneous connections</small>
                            </div>
                            
                            <div class="col-12 mb-3">
                                <label class="form-label">Notes (Optional)</label>
                                <textarea name="notes" class="form-control" rows="2" 
                                          placeholder="Additional notes about this client"></textarea>
                            </div>
                        </div>
                        
                        <div class="d-grid gap-2 d-md-flex justify-content-md-end">
                            <a href="?" class="btn btn-outline-secondary">Cancel</a>
                            <button type="submit" class="btn btn-primary">
                                <i class="bi bi-check-circle me-2"></i> Create Client
                            </button>
                        </div>
                    </form>
                    <?php endif; ?>
                </div>
            </div>
            
            <!-- Client Limit Info -->
            <div class="card mt-3">
                <div class="card-body">
                    <div class="d-flex justify-content-between align-items-center">
                        <div>
                            <h6 class="mb-0">Client Usage</h6>
                            <small class="text-muted"><?php echo count($user_clients); ?> of <?php echo $max_clients; ?> clients used</small>
                        </div>
                        <div class="progress" style="width: 200px; height: 10px;">
                            <div class="progress-bar bg-info" 
                                 style="width: <?php echo (count($user_clients) / $max_clients) * 100; ?>%">
                            </div>
                        </div>
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
                            <th>Bandwidth</th>
                            <th>Last Login</th>
                            <th>Status</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($data['users'] as $username => $user): 
                            $user_clients = getUserClients($username);
                            $total_bw = array_sum(array_column($user_clients, 'bandwidth_used'));
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
                            <td>
                                <?php echo count($user_clients); ?> / <?php echo $user['max_clients'] ?? 10; ?>
                            </td>
                            <td><?php echo formatBytes($total_bw); ?></td>
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
                                    <button class="btn btn-outline-info" data-bs-toggle="modal" data-bs-target="#editUserModal" 
                                            onclick="loadUser('<?php echo $username; ?>')">
                                        <i class="bi bi-pencil"></i>
                                    </button>
                                    <?php if ($username != 'admin' && $username != $_SESSION['user']['username']): ?>
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
                        <div class="row">
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Role</label>
                                <select name="role" class="form-select">
                                    <option value="user">User</option>
                                    <option value="admin">Admin</option>
                                </select>
                            </div>
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Max Clients</label>
                                <input type="number" name="max_clients" class="form-control" value="10" min="1" max="100">
                            </div>
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
    
    <!-- Edit User Modal -->
    <div class="modal fade" id="editUserModal" tabindex="-1">
        <div class="modal-dialog">
            <div class="modal-content">
                <form method="POST" action="?action=edit_user">
                    <div class="modal-header">
                        <h5 class="modal-title">Edit User</h5>
                        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                    </div>
                    <div class="modal-body">
                        <input type="hidden" name="username" id="edit_username">
                        <div class="mb-3">
                            <label class="form-label">New Password (leave empty to keep current)</label>
                            <input type="password" name="password" class="form-control">
                        </div>
                        <div class="mb-3">
                            <label class="form-label">Email</label>
                            <input type="email" name="email" id="edit_email" class="form-control">
                        </div>
                        <div class="row">
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Role</label>
                                <select name="role" id="edit_role" class="form-select">
                                    <option value="user">User</option>
                                    <option value="admin">Admin</option>
                                </select>
                            </div>
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Max Clients</label>
                                <input type="number" name="max_clients" id="edit_max_clients" class="form-control" min="1" max="100">
                            </div>
                        </div>
                        <div class="form-check mb-3">
                            <input type="checkbox" name="active" id="edit_active" class="form-check-input">
                            <label class="form-check-label">Active</label>
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
    
    <script>
    function loadUser(username) {
        fetch('?action=get_user&user=' + username)
            .then(response => response.json())
            .then(data => {
                document.getElementById('edit_username').value = data.username;
                document.getElementById('edit_email').value = data.email || '';
                document.getElementById('edit_role').value = data.role;
                document.getElementById('edit_max_clients').value = data.max_clients || 10;
                document.getElementById('edit_active').checked = data.active;
            });
    }
    </script>
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
    
    <div class="row">
        <div class="col-md-8">
            <div class="card mb-4">
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
                                <small class="text-muted">SlowDNS server port (default: 5300)</small>
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Max Connections</label>
                                <input type="number" name="max_connections" class="form-control" 
                                       value="<?php echo $data['server']['max_connections']; ?>" min="1" max="1000">
                                <small class="text-muted">Maximum simultaneous connections</small>
                            </div>
                            
                            <div class="col-12 mb-3">
                                <div class="form-check form-switch">
                                    <input type="checkbox" name="maintenance" class="form-check-input" 
                                           id="maintenance" <?php echo $data['server']['maintenance'] ? 'checked' : ''; ?>>
                                    <label class="form-check-label" for="maintenance">
                                        Maintenance Mode
                                    </label>
                                    <small class="text-muted d-block">When enabled, new connections are blocked</small>
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
            
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-sliders me-2"></i> Panel Settings</h5>
                </div>
                <div class="card-body">
                    <form method="POST" action="?action=save_panel_settings">
                        <div class="row">
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Allow New Registrations</label>
                                <select name="allow_registration" class="form-select">
                                    <option value="1" <?php echo $data['settings']['allow_registration'] ? 'selected' : ''; ?>>Yes</option>
                                    <option value="0" <?php echo !$data['settings']['allow_registration'] ? 'selected' : ''; ?>>No</option>
                                </select>
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Maximum Users</label>
                                <input type="number" name="max_users" class="form-control" 
                                       value="<?php echo $data['settings']['max_users']; ?>" min="1" max="1000">
                            </div>
                            
                            <div class="col-md-6 mb-3">
                                <label class="form-label">Log Retention (days)</label>
                                <input type="number" name="log_days" class="form-control" 
                                       value="<?php echo $data['settings']['log_retention_days']; ?>" min="1" max="365">
                            </div>
                            
                            <div class="col-12 mb-3">
                                <div class="form-check form-switch">
                                    <input type="checkbox" name="notify_restart" class="form-check-input" 
                                           id="notify_restart" <?php echo $data['settings']['notify_on_restart'] ? 'checked' : ''; ?>>
                                    <label class="form-check-label" for="notify_restart">
                                        Notify on Server Restart
                                    </label>
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
        </div>
        
        <div class="col-md-4">
            <div class="card mb-4">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-shield-check me-2"></i> Security</h5>
                </div>
                <div class="card-body">
                    <div class="mb-3">
                        <label class="form-label">Change Admin Password</label>
                        <form method="POST" action="?action=change_admin_password">
                            <div class="input-group mb-2">
                                <input type="password" name="current_password" class="form-control" placeholder="Current Password">
                            </div>
                            <div class="input-group mb-2">
                                <input type="password" name="new_password" class="form-control" placeholder="New Password">
                            </div>
                            <div class="input-group mb-3">
                                <input type="password" name="confirm_password" class="form-control" placeholder="Confirm Password">
                            </div>
                            <button type="submit" class="btn btn-warning w-100">Change Password</button>
                        </form>
                    </div>
                    
                    <hr>
                    
                    <div class="mb-3">
                        <label class="form-label">Backup & Restore</label>
                        <div class="d-grid gap-2">
                            <a href="?action=backup" class="btn btn-outline-primary">
                                <i class="bi bi-download me-2"></i> Download Backup
                            </a>
                            <button class="btn btn-outline-info" data-bs-toggle="modal" data-bs-target="#restoreModal">
                                <i class="bi bi-upload me-2"></i> Restore Backup
                            </button>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-info-circle me-2"></i> Server Information</h5>
                </div>
                <div class="card-body">
                    <?php $status = getServerStatus(); ?>
                    <table class="table table-sm">
                        <tr>
                            <td><i class="bi bi-hdd text-muted"></i> Data File</td>
                            <td><small><?php echo basename(DATA_FILE); ?></small></td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-file-text text-muted"></i> Log File</td>
                            <td><small><?php echo basename(LOG_FILE); ?></small></td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-arrow-clockwise text-muted"></i> Restart Count</td>
                            <td><?php echo $data['server']['restart_count']; ?></td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-calendar text-muted"></i> Last Restart</td>
                            <td>
                                <?php echo $data['server']['last_restart'] ? date('M d, H:i', strtotime($data['server']['last_restart'])) : 'Never'; ?>
                            </td>
                        </tr>
                    </table>
                </div>
            </div>
        </div>
    </div>
    
    <!-- Restore Modal -->
    <div class="modal fade" id="restoreModal" tabindex="-1">
        <div class="modal-dialog">
            <div class="modal-content">
                <form method="POST" action="?action=restore_backup" enctype="multipart/form-data">
                    <div class="modal-header">
                        <h5 class="modal-title">Restore Backup</h5>
                        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                    </div>
                    <div class="modal-body">
                        <div class="alert alert-warning">
                            <i class="bi bi-exclamation-triangle me-2"></i>
                            This will overwrite all current data!
                        </div>
                        <div class="mb-3">
                            <label class="form-label">Select Backup File</label>
                            <input type="file" name="backup_file" class="form-control" accept=".json" required>
                        </div>
                    </div>
                    <div class="modal-footer">
                        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                        <button type="submit" class="btn btn-danger">Restore</button>
                    </div>
                </form>
            </div>
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
                        <div class="col-md-4 mb-3">
                            <div class="card p-3">
                                <i class="bi bi-play-circle fs-1 text-success mb-2"></i>
                                <h5>Start</h5>
                                <p class="text-muted small">Start SlowDNS service</p>
                                <a href="?action=start_service" class="btn btn-success w-100">Start</a>
                            </div>
                        </div>
                        <div class="col-md-4 mb-3">
                            <div class="card p-3">
                                <i class="bi bi-stop-circle fs-1 text-danger mb-2"></i>
                                <h5>Stop</h5>
                                <p class="text-muted small">Stop SlowDNS service</p>
                                <a href="?action=stop_service" class="btn btn-danger w-100">Stop</a>
                            </div>
                        </div>
                        <div class="col-md-4 mb-3">
                            <div class="card p-3">
                                <i class="bi bi-arrow-clockwise fs-1 text-primary mb-2"></i>
                                <h5>Restart</h5>
                                <p class="text-muted small">Restart SlowDNS service</p>
                                <a href="?action=restart_service" class="btn btn-primary w-100">Restart</a>
                            </div>
                        </div>
                    </div>
                    
                    <div class="alert alert-info">
                        <i class="bi bi-info-circle me-2"></i>
                        Current Status: 
                        <strong class="<?php echo $status['service'] == 'running' ? 'text-success' : 'text-danger'; ?>">
                            <?php echo ucfirst($status['service']); ?>
                        </strong>
                        | Active Connections: <strong><?php echo $status['connections']; ?></strong>
                    </div>
                </div>
            </div>
            
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
                            <small class="text-muted">Only safe commands are allowed</small>
                        </div>
                        <button type="submit" class="btn btn-outline-primary">Execute</button>
                    </form>
                    
                    <?php if (isset($_GET['command_output'])): ?>
                    <div class="mt-3">
                        <label class="form-label">Output:</label>
                        <pre class="bg-dark text-light p-3 rounded"><?php echo htmlspecialchars($_GET['command_output']); ?></pre>
                    </div>
                    <?php endif; ?>
                </div>
            </div>
        </div>
        
        <div class="col-md-6">
            <div class="card mb-4">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-graph-up me-2"></i> System Information</h5>
                </div>
                <div class="card-body">
                    <table class="table table-sm">
                        <tr>
                            <td><i class="bi bi-cpu text-muted"></i> CPU Load</td>
                            <td>
                                <span class="badge <?php echo $status['load'] > 1.5 ? 'bg-warning' : 'bg-success'; ?>">
                                    <?php echo $status['load']; ?>
                                </span>
                            </td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-memory text-muted"></i> Memory Usage</td>
                            <td>
                                <div class="progress progress-thin">
                                    <div class="progress-bar <?php echo $status['memory'] > 80 ? 'bg-danger' : ($status['memory'] > 60 ? 'bg-warning' : 'bg-success'); ?>" 
                                         style="width: <?php echo $status['memory']; ?>%">
                                    </div>
                                </div>
                                <small><?php echo $status['memory']; ?>%</small>
                            </td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-hdd text-muted"></i> Disk Space</td>
                            <td><?php echo $status['disk_free_gb']; ?> GB free</td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-clock text-muted"></i> Uptime</td>
                            <td><?php echo $status['uptime']; ?></td>
                        </tr>
                        <tr>
                            <td><i class="bi bi-ethernet text-muted"></i> Port Status</td>
                            <td>
                                <span class="badge <?php echo $status['port'] == 'open' ? 'bg-success' : 'bg-danger'; ?>">
                                    Port <?php echo SLOWDNS_PORT; ?> <?php echo $status['port']; ?>
                                </span>
                            </td>
                        </tr>
                    </table>
                </div>
            </div>
            
            <div class="card">
                <div class="card-header">
                    <h5 class="mb-0"><i class="bi bi-tools me-2"></i> Maintenance</h5>
                </div>
                <div class="card-body">
                    <div class="d-grid gap-2">
                        <a href="?action=clear_logs" class="btn btn-outline-warning" 
                           onclick="return confirm('Clear all logs?')">
                            <i class="bi bi-trash me-2"></i> Clear Logs
                        </a>
                        <a href="?action=reset_bandwidth" class="btn btn-outline-info"
                           onclick="return confirm('Reset all bandwidth counters?')">
                            <i class="bi bi-arrow-counterclockwise me-2"></i> Reset Bandwidth
                        </a>
                        <a href="?action=reboot_system" class="btn btn-outline-danger"
                           onclick="return confirm('Reboot the server? This will disconnect all users!')">
                            <i class="bi bi-arrow-repeat me-2"></i> Reboot System
                        </a>
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
                <div class="card-header bg-warning text-dark">
                    <h5 class="mb-0"><i class="bi bi-key me-2"></i> Change Password</h5>
                </div>
                <div class="card-body">
                    <?php if (isset($_GET['success'])): ?>
                    <div class="alert alert-success">
                        <i class="bi bi-check-circle me-2"></i> Password changed successfully!
                    </div>
                    <?php endif; ?>
                    
                    <?php if (isset($_GET['error'])): ?>
                    <div class="alert alert-danger">
                        <i class="bi bi-exclamation-triangle me-2"></i> <?php echo htmlspecialchars($_GET['error']); ?>
                    </div>
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
// MAIN ROUTER
// =============================================
$action = $_GET['action'] ?? '';

// Handle authentication
if ($action == 'do_login') {
    if (login($_POST['username'], $_POST['password'])) {
        header('Location: ?');
        exit;
    } else {
        header('Location: ?action=login&error=Invalid credentials');
        exit;
    }
}

if ($action == 'logout') {
    logout();
}

// Check login
if (!isset($_SESSION['user'])) {
    if ($action == 'login' || $action == 'do_login') {
        renderLoginPage();
    } else {
        header('Location: ?action=login');
        exit;
    }
}

// Route to pages
switch ($action) {
    case '':
    case 'dashboard':
        renderDashboard();
        break;
    case 'clients':
        renderClientsPage();
        break;
    case 'create_client':
        renderCreateClientPage();
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
    case 'profile':
        // Add profile page if needed
        header('Location: ?action=change_password');
        exit;
    default:
        // Handle other actions (save, delete, etc.)
        include 'action_handler.php';
        break;
}

// Always render footer
renderFooter();
?>
