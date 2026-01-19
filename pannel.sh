#!/bin/bash

echo "Installing SlowDNS Web Panel..."
echo "=================================="

# Install required packages
apt update
apt install -y php php-curl php-mysql php-gd php-mbstring php-xml php-zip apache2 mariadb-server git curl wget unzip

# Configure PHP
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 50M/' /etc/php/*/apache2/php.ini
sed -i 's/post_max_size = .*/post_max_size = 50M/' /etc/php/*/apache2/php.ini
sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/*/apache2/php.ini

# Create web directory
WEB_DIR="/var/www/slowdns-panel"
mkdir -p $WEB_DIR
cd $WEB_DIR

# Create single-file web panel
cat > index.php << 'EOF'
<?php
/**
 * SlowDNS Web Panel - Single File Edition
 * One file to rule them all!
 */

// ================================
// CONFIGURATION
// ================================
$config = [
    'site_name' => 'SlowDNS Manager',
    'admin_user' => 'admin',
    'admin_pass' => 'admin123', // CHANGE THIS!
    'slowdns_port' => 5300,
    'slowdns_dir' => '/etc/slowdns',
    'data_file' => __DIR__ . '/data.json',
    'log_file' => __DIR__ . '/slowdns.log',
    'default_limit_mb' => 1024 // 1GB
];

// ================================
// HELPER FUNCTIONS
// ================================
function getUsers() {
    global $config;
    if (!file_exists($config['data_file'])) return [];
    $data = json_decode(file_get_contents($config['data_file']), true);
    return $data['users'] ?? [];
}

function saveUsers($users) {
    global $config;
    $data = ['users' => $users, 'clients' => getClients()];
    file_put_contents($config['data_file'], json_encode($data, JSON_PRETTY_PRINT));
}

function getClients() {
    global $config;
    if (!file_exists($config['data_file'])) return [];
    $data = json_decode(file_get_contents($config['data_file']), true);
    return $data['clients'] ?? [];
}

function saveClients($clients) {
    global $config;
    $data = ['users' => getUsers(), 'clients' => $clients];
    file_put_contents($config['data_file'], json_encode($data, JSON_PRETTY_PRINT));
}

function generateKey() {
    return bin2hex(random_bytes(32));
}

function createClientConfig($name, $domain, $public_key) {
    global $config;
    $server_ip = $_SERVER['SERVER_ADDR'] ?? gethostbyname(gethostname());
    
    $config_content = "[client]\n";
    $config_content .= "server = $server_ip\n";
    $config_content .= "port = {$config['slowdns_port']}\n";
    $config_content .= "public_key = " . base64_encode($public_key) . "\n";
    $config_content .= "domain = " . ($domain ?: "dns.$server_ip.nip.io") . "\n";
    $config_content .= "mtu = 1200\n";
    $config_content .= "protocol = udp\n";
    
    return $config_content;
}

function getServerStatus() {
    global $config;
    $status = [];
    
    // Check SlowDNS service
    exec('systemctl is-active server-sldns.service 2>/dev/null', $output, $code);
    $status['slowdns_running'] = ($code == 0);
    
    // Check port
    exec("netstat -tulpn 2>/dev/null | grep :{$config['slowdns_port']}", $output);
    $status['port_open'] = !empty($output);
    
    // Get connections
    exec("netstat -anp 2>/dev/null | grep :{$config['slowdns_port']} | grep ESTABLISHED | wc -l", $output);
    $status['connections'] = intval($output[0] ?? 0);
    
    // Get server load
    $load = sys_getloadavg();
    $status['load'] = $load[0];
    
    // Get memory
    $mem = shell_exec("free | grep Mem | awk '{print $3/$2 * 100.0}'");
    $status['memory'] = round(floatval($mem), 2);
    
    return $status;
}

function restartSlowDNS() {
    exec('systemctl restart server-sldns.service 2>&1', $output, $code);
    return $code == 0;
}

function logMessage($message) {
    global $config;
    $log = date('Y-m-d H:i:s') . " - $message\n";
    file_put_contents($config['log_file'], $log, FILE_APPEND);
}

// ================================
// SESSION & AUTH
// ================================
session_start();

// Initialize data file
if (!file_exists($config['data_file'])) {
    $initial_data = [
        'users' => [
            $config['admin_user'] => [
                'password' => password_hash($config['admin_pass'], PASSWORD_DEFAULT),
                'is_admin' => true,
                'created' => date('Y-m-d H:i:s')
            ]
        ],
        'clients' => []
    ];
    file_put_contents($config['data_file'], json_encode($initial_data, JSON_PRETTY_PRINT));
}

// Authentication
function isLoggedIn() {
    return isset($_SESSION['user']) && !empty($_SESSION['user']);
}

function login($username, $password) {
    $users = getUsers();
    if (isset($users[$username]) && password_verify($password, $users[$username]['password'])) {
        $_SESSION['user'] = [
            'username' => $username,
            'is_admin' => $users[$username]['is_admin'] ?? false
        ];
        return true;
    }
    return false;
}

function logout() {
    session_destroy();
    header('Location: ?');
    exit;
}

// ================================
// HTML TEMPLATES
// ================================
function renderHeader($title) {
    global $config;
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title><?php echo $title; ?> - <?php echo $config['site_name']; ?></title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
        <style>
            body { background-color: #f8f9fa; }
            .navbar { box-shadow: 0 2px 4px rgba(0,0,0,.1); }
            .card { border: none; box-shadow: 0 0 15px rgba(0,0,0,.05); }
            .status-online { color: #28a745; }
            .status-offline { color: #dc3545; }
            .client-card { transition: transform 0.2s; }
            .client-card:hover { transform: translateY(-5px); }
        </style>
    </head>
    <body>
        <nav class="navbar navbar-expand-lg navbar-dark bg-primary">
            <div class="container">
                <a class="navbar-brand" href="?"><i class="bi bi-shield-lock"></i> <?php echo $config['site_name']; ?></a>
                <?php if (isLoggedIn()): ?>
                <div class="navbar-nav ms-auto">
                    <span class="navbar-text me-3">
                        <i class="bi bi-person-circle"></i> <?php echo $_SESSION['user']['username']; ?>
                    </span>
                    <a href="?action=logout" class="btn btn-outline-light btn-sm">Logout</a>
                </div>
                <?php endif; ?>
            </div>
        </nav>
        <div class="container mt-4">
    <?php
}

function renderFooter() {
    ?>
        </div>
        <footer class="mt-5 py-3 text-center text-muted">
            <small>SlowDNS Panel v1.0 &copy; <?php echo date('Y'); ?></small>
        </footer>
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
        <script>
            // Auto refresh every 30 seconds
            setTimeout(() => location.reload(), 30000);
            
            // Copy to clipboard
            function copyToClipboard(text) {
                navigator.clipboard.writeText(text).then(() => {
                    alert('Copied to clipboard!');
                });
            }
            
            // Download config
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

function renderLoginForm() {
    $error = $_GET['error'] ?? '';
    ?>
    <div class="row justify-content-center mt-5">
        <div class="col-md-4">
            <div class="card">
                <div class="card-header bg-primary text-white text-center">
                    <h4><i class="bi bi-shield-lock"></i> Login</h4>
                </div>
                <div class="card-body">
                    <?php if ($error): ?>
                    <div class="alert alert-danger"><?php echo htmlspecialchars($error); ?></div>
                    <?php endif; ?>
                    <form method="POST" action="?action=login">
                        <div class="mb-3">
                            <label for="username" class="form-label">Username</label>
                            <input type="text" class="form-control" id="username" name="username" required>
                        </div>
                        <div class="mb-3">
                            <label for="password" class="form-label">Password</label>
                            <input type="password" class="form-control" id="password" name="password" required>
                        </div>
                        <button type="submit" class="btn btn-primary w-100">Login</button>
                    </form>
                    <div class="text-center mt-3">
                        <small>Default: admin / admin123</small>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php
}

function renderDashboard() {
    global $config;
    $status = getServerStatus();
    $clients = getClients();
    $user_clients = array_filter($clients, function($c) {
        return $c['owner'] == $_SESSION['user']['username'];
    });
    
    // Calculate stats
    $total_clients = count($user_clients);
    $active_clients = count(array_filter($user_clients, function($c) { return $c['active']; }));
    $total_bw = array_sum(array_column($user_clients, 'bandwidth_used'));
    
    ?>
    <div class="row mb-4">
        <!-- Server Status -->
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">
                    <h5><i class="bi bi-server"></i> Server Status</h5>
                </div>
                <div class="card-body">
                    <div class="row">
                        <div class="col-6">
                            <div class="d-flex align-items-center mb-3">
                                <div class="me-3">
                                    <i class="bi bi-power <?php echo $status['slowdns_running'] ? 'status-online' : 'status-offline'; ?>" style="font-size: 2rem;"></i>
                                </div>
                                <div>
                                    <small class="text-muted">SlowDNS Service</small>
                                    <h5><?php echo $status['slowdns_running'] ? 'RUNNING' : 'STOPPED'; ?></h5>
                                </div>
                            </div>
                        </div>
                        <div class="col-6">
                            <div class="d-flex align-items-center mb-3">
                                <div class="me-3">
                                    <i class="bi bi-ethernet <?php echo $status['port_open'] ? 'status-online' : 'status-offline'; ?>" style="font-size: 2rem;"></i>
                                </div>
                                <div>
                                    <small class="text-muted">Port <?php echo $config['slowdns_port']; ?></small>
                                    <h5><?php echo $status['port_open'] ? 'OPEN' : 'CLOSED'; ?></h5>
                                </div>
                            </div>
                        </div>
                        <div class="col-6">
                            <div class="d-flex align-items-center">
                                <div class="me-3">
                                    <i class="bi bi-people" style="font-size: 2rem; color: #6c757d;"></i>
                                </div>
                                <div>
                                    <small class="text-muted">Active Connections</small>
                                    <h5><?php echo $status['connections']; ?></h5>
                                </div>
                            </div>
                        </div>
                        <div class="col-6">
                            <div class="d-flex align-items-center">
                                <div class="me-3">
                                    <i class="bi bi-speedometer2" style="font-size: 2rem; color: #6c757d;"></i>
                                </div>
                                <div>
                                    <small class="text-muted">Server Load</small>
                                    <h5><?php echo $status['load']; ?></h5>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- User Stats -->
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">
                    <h5><i class="bi bi-bar-chart"></i> Your Statistics</h5>
                </div>
                <div class="card-body">
                    <div class="row text-center">
                        <div class="col-4">
                            <div class="display-6 text-primary"><?php echo $total_clients; ?></div>
                            <small class="text-muted">Total Clients</small>
                        </div>
                        <div class="col-4">
                            <div class="display-6 text-success"><?php echo $active_clients; ?></div>
                            <small class="text-muted">Active Clients</small>
                        </div>
                        <div class="col-4">
                            <div class="display-6 text-info"><?php echo round($total_bw / 1024 / 1024, 2); ?> MB</div>
                            <small class="text-muted">Bandwidth Used</small>
                        </div>
                    </div>
                    <div class="mt-3">
                        <a href="?action=create" class="btn btn-primary w-100">
                            <i class="bi bi-plus-circle"></i> Create New Client
                        </a>
                    </div>
                </div>
            </div>
        </div>
    </div>
    
    <!-- Client List -->
    <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center">
            <h5><i class="bi bi-person-badge"></i> Your SlowDNS Clients</h5>
            <span class="badge bg-primary"><?php echo count($user_clients); ?> clients</span>
        </div>
        <div class="card-body">
            <?php if (empty($user_clients)): ?>
            <div class="text-center py-5">
                <i class="bi bi-person-x display-1 text-muted"></i>
                <h4 class="mt-3">No clients yet</h4>
                <p>Create your first SlowDNS client to get started</p>
                <a href="?action=create" class="btn btn-primary btn-lg">
                    <i class="bi bi-plus-circle"></i> Create First Client
                </a>
            </div>
            <?php else: ?>
            <div class="row">
                <?php foreach ($user_clients as $id => $client): 
                    $bw_used = round($client['bandwidth_used'] / 1024 / 1024, 2);
                    $bw_limit = round($client['bandwidth_limit'] / 1024 / 1024, 2);
                    $percent = min(100, ($bw_used / $bw_limit) * 100);
                ?>
                <div class="col-md-6 mb-3">
                    <div class="card client-card h-100">
                        <div class="card-body">
                            <div class="d-flex justify-content-between align-items-start mb-3">
                                <div>
                                    <h5 class="card-title">
                                        <?php echo htmlspecialchars($client['name']); ?>
                                        <span class="badge bg-<?php echo $client['active'] ? 'success' : 'danger'; ?>">
                                            <?php echo $client['active'] ? 'Active' : 'Inactive'; ?>
                                        </span>
                                    </h5>
                                    <p class="card-text">
                                        <small class="text-muted">
                                            <i class="bi bi-globe"></i> <?php echo htmlspecialchars($client['domain']); ?>
                                        </small>
                                    </p>
                                </div>
                                <div class="dropdown">
                                    <button class="btn btn-sm btn-outline-secondary dropdown-toggle" type="button" data-bs-toggle="dropdown">
                                        <i class="bi bi-gear"></i>
                                    </button>
                                    <ul class="dropdown-menu">
                                        <li><a class="dropdown-item" href="#" onclick="copyToClipboard('<?php echo base64_encode($client['config']); ?>')">
                                            <i class="bi bi-clipboard"></i> Copy Config
                                        </a></li>
                                        <li><a class="dropdown-item" href="#" onclick="downloadConfig('<?php echo $client['name']; ?>', '<?php echo addslashes($client['config']); ?>')">
                                            <i class="bi bi-download"></i> Download
                                        </a></li>
                                        <li><hr class="dropdown-divider"></li>
                                        <li><a class="dropdown-item text-danger" href="?action=delete&id=<?php echo $id; ?>" onclick="return confirm('Delete this client?')">
                                            <i class="bi bi-trash"></i> Delete
                                        </a></li>
                                    </ul>
                                </div>
                            </div>
                            
                            <div class="mb-3">
                                <small class="text-muted">Bandwidth Usage</small>
                                <div class="progress" style="height: 10px;">
                                    <div class="progress-bar <?php echo $percent > 80 ? 'bg-danger' : ($percent > 50 ? 'bg-warning' : 'bg-success'); ?>" 
                                         role="progressbar" 
                                         style="width: <?php echo $percent; ?>%">
                                    </div>
                                </div>
                                <div class="text-end">
                                    <small><?php echo $bw_used; ?>MB / <?php echo $bw_limit; ?>MB</small>
                                </div>
                            </div>
                            
                            <div class="text-muted small">
                                <i class="bi bi-calendar"></i> Created: <?php echo $client['created']; ?>
                                <?php if ($client['last_used']): ?>
                                <br><i class="bi bi-clock"></i> Last used: <?php echo $client['last_used']; ?>
                                <?php endif; ?>
                            </div>
                        </div>
                    </div>
                </div>
                <?php endforeach; ?>
            </div>
            <?php endif; ?>
        </div>
    </div>
    <?php
}

function renderCreateForm() {
    ?>
    <div class="row justify-content-center">
        <div class="col-md-6">
            <div class="card">
                <div class="card-header bg-primary text-white">
                    <h5><i class="bi bi-plus-circle"></i> Create New Client</h5>
                </div>
                <div class="card-body">
                    <form method="POST" action="?action=save">
                        <div class="mb-3">
                            <label for="name" class="form-label">Client Name</label>
                            <input type="text" class="form-control" id="name" name="name" required placeholder="My Phone / Laptop">
                        </div>
                        <div class="mb-3">
                            <label for="domain" class="form-label">Domain (Optional)</label>
                            <input type="text" class="form-control" id="domain" name="domain" placeholder="dns.example.com">
                            <small class="text-muted">Leave empty for auto-generated domain</small>
                        </div>
                        <div class="mb-3">
                            <label for="limit" class="form-label">Bandwidth Limit (MB)</label>
                            <input type="number" class="form-control" id="limit" name="limit" value="1024" min="100" max="10240">
                            <small class="text-muted">Monthly bandwidth limit</small>
                        </div>
                        <div class="d-grid gap-2">
                            <button type="submit" class="btn btn-primary">
                                <i class="bi bi-check-circle"></i> Create Client
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

function renderConfigView($client_id) {
    $clients = getClients();
    if (!isset($clients[$client_id]) || $clients[$client_id]['owner'] != $_SESSION['user']['username']) {
        echo "Client not found!";
        return;
    }
    
    $client = $clients[$client_id];
    ?>
    <div class="row justify-content-center">
        <div class="col-md-8">
            <div class="card">
                <div class="card-header bg-info text-white">
                    <h5><i class="bi bi-code"></i> Configuration: <?php echo htmlspecialchars($client['name']); ?></h5>
                </div>
                <div class="card-body">
                    <div class="mb-3">
                        <pre class="bg-dark text-light p-3 rounded" style="font-size: 12px;"><?php echo htmlspecialchars($client['config']); ?></pre>
                    </div>
                    <div class="text-center mb-3">
                        <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=<?php echo urlencode($client['config']); ?>" 
                             alt="QR Code" class="img-fluid" style="max-width: 200px;">
                        <p class="text-muted mt-2">Scan QR code with SlowDNS client</p>
                    </div>
                    <div class="d-grid gap-2">
                        <button class="btn btn-success" onclick="copyToClipboard('<?php echo addslashes($client['config']); ?>')">
                            <i class="bi bi-clipboard"></i> Copy Configuration
                        </button>
                        <button class="btn btn-primary" onclick="downloadConfig('<?php echo $client['name']; ?>', '<?php echo addslashes($client['config']); ?>')">
                            <i class="bi bi-download"></i> Download Config File
                        </button>
                        <a href="?" class="btn btn-outline-secondary">Back to Dashboard</a>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <?php
}

// ================================
// MAIN ROUTING LOGIC
// ================================
$action = $_GET['action'] ?? '';

// Handle POST actions
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    if ($action == 'login') {
        if (login($_POST['username'], $_POST['password'])) {
            header('Location: ?');
            exit;
        } else {
            header('Location: ?error=Invalid%20username%20or%20password');
            exit;
        }
    }
    
    if ($action == 'save' && isLoggedIn()) {
        $name = $_POST['name'];
        $domain = $_POST['domain'];
        $limit = intval($_POST['limit']) * 1024 * 1024; // Convert MB to bytes
        
        $private_key = generateKey();
        $public_key = generateKey();
        $config = createClientConfig($name, $domain, $public_key);
        
        $clients = getClients();
        $client_id = uniqid();
        
        $clients[$client_id] = [
            'name' => $name,
            'domain' => $domain ?: 'auto',
            'owner' => $_SESSION['user']['username'],
            'public_key' => $public_key,
            'private_key' => $private_key,
            'config' => $config,
            'bandwidth_limit' => $limit,
            'bandwidth_used' => 0,
            'active' => true,
            'created' => date('Y-m-d H:i:s'),
            'last_used' => null
        ];
        
        saveClients($clients);
        logMessage("Client created: $name by {$_SESSION['user']['username']}");
        
        header('Location: ?action=config&id=' . $client_id);
        exit;
    }
}

// Handle GET actions
if ($action == 'logout') {
    logout();
}

if ($action == 'delete' && isLoggedIn()) {
    $id = $_GET['id'] ?? '';
    $clients = getClients();
    
    if (isset($clients[$id]) && $clients[$id]['owner'] == $_SESSION['user']['username']) {
        unset($clients[$id]);
        saveClients($clients);
        logMessage("Client deleted: {$id} by {$_SESSION['user']['username']}");
    }
    
    header('Location: ?');
    exit;
}

// ================================
// RENDER PAGE
// ================================
renderHeader($config['site_name']);

if (!isLoggedIn()) {
    renderLoginForm();
} else {
    switch ($action) {
        case 'create':
            renderCreateForm();
            break;
        case 'config':
            $client_id = $_GET['id'] ?? '';
            renderConfigView($client_id);
            break;
        default:
            renderDashboard();
            break;
    }
}

renderFooter();
EOF

# Set permissions
chown -R www-data:www-data $WEB_DIR
chmod -R 755 $WEB_DIR

# Create Apache config
cat > /etc/apache2/sites-available/slowdns-panel.conf << EOF
<VirtualHost *:80>
    ServerName your-domain.com
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
a2enmod rewrite

# Restart Apache
systemctl restart apache2

# Configure firewall
ufw allow 80/tcp
ufw allow 443/tcp

echo ""
echo "========================================="
echo "SlowDNS Web Panel Installed Successfully!"
echo "========================================="
echo ""
echo "Access your panel at:"
echo "http://$(curl -s ifconfig.me)/"
echo "or"
echo "http://your-server-ip/"
echo ""
echo "Default login:"
echo "Username: admin"
echo "Password: admin123"
echo ""
echo "IMPORTANT: Change the default password!"
echo "Edit $WEB_DIR/index.php and modify 'admin_pass'"
echo ""
echo "To enable HTTPS (SSL):"
echo "certbot --apache -d your-domain.com"
echo ""
