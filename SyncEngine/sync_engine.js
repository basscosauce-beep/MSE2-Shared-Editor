const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SHARED_DIR = path.join(__dirname, '..', 'Shared-Set');
let isSyncing = false;
let pendingChanges = false;

// Ensure the git command uses mingit
const env = Object.assign({}, process.env);
env.PATH = `${path.join(__dirname, '..', 'mingit', 'cmd')};${env.PATH}`;

if (!fs.existsSync(SHARED_DIR)) {
    fs.mkdirSync(SHARED_DIR);
}

function runCommand(command) {
    try {
        execSync(command, { env: env, cwd: path.join(__dirname, '..'), stdio: 'ignore' });
        return true;
    } catch (e) {
        return false;
    }
}

async function syncWithGitHub() {
    if (isSyncing) return;
    isSyncing = true;
    pendingChanges = false;

    console.log(`[Sync Engine] Change detected! Pushing cards to GitHub...`);
    
    // Add, commit, and push
    runCommand('git add Shared-Set/');
    const commitSuccess = runCommand('git commit -m "Auto-sync card updates"');
    
    if (commitSuccess) {
        console.log(`[Sync Engine] Uploading to cloud...`);
        runCommand('git push origin main');
        console.log(`[Sync Engine] Successfully synced!`);
    } else {
        console.log(`[Sync Engine] No new card changes to push.`);
    }

    isSyncing = false;

    // If changes happened while we were syncing, sync again
    if (pendingChanges) {
        syncWithGitHub();
    }
}

// Watch the directory for any saved files from MSE2
console.log('[Sync Engine] Background Sync Engine Active! Watching for card saves...');

fs.watch(SHARED_DIR, { recursive: true }, (eventType, filename) => {
    if (filename && !filename.startsWith('.git')) {
        if (!isSyncing) {
            // Debounce the sync to prevent multiple rapid pushes
            setTimeout(syncWithGitHub, 2000);
        } else {
            pendingChanges = true;
        }
    }
});

// Setup a polling interval to pull new cards from friends every 30 seconds
setInterval(() => {
    if (!isSyncing) {
        // Silently pull updates from GitHub
        runCommand('git pull origin main');
    }
}, 30000);
