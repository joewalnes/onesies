// AIDEV-NOTE: Example userscript demonstrating Onesies single-file principle
// Simple browser greeting userscript - paste into dev console to run

/**
 * Hello Userscript
 * 
 * A simple greeting tool for browser developer console.
 * Demonstrates DOM manipulation and user interaction.
 * 
 * Usage:
 *   1. Open browser developer console (F12)
 *   2. Paste this entire script
 *   3. Press Enter to execute
 * 
 * Features:
 *   - Creates a floating greeting dialog
 *   - Customizable name input
 *   - Timestamp option
 *   - Uppercase option
 *   - Auto-removes after timeout or click
 */

(function() {
    'use strict';
    
    console.log('🎉 Hello Userscript loaded!');
    
    // Configuration
    const CONFIG = {
        timeout: 5000, // Auto-hide after 5 seconds
        defaultName: 'Web Explorer',
        colors: {
            primary: '#4CAF50',
            secondary: '#45a049',
            text: '#ffffff',
            background: 'rgba(0, 0, 0, 0.8)'
        }
    };
    
    // Create and show greeting dialog
    function showGreeting(options = {}) {
        const name = options.name || CONFIG.defaultName;
        const includeTime = options.includeTime || false;
        const uppercase = options.uppercase || false;
        
        // Build greeting message
        let message = `Hello, ${name}!`;
        
        if (includeTime) {
            const now = new Date();
            const timeString = now.toLocaleString();
            message += ` (at ${timeString})`;
        }
        
        if (uppercase) {
            message = message.toUpperCase();
        }
        
        // Create dialog element
        const dialog = document.createElement('div');
        dialog.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: ${CONFIG.colors.primary};
            color: ${CONFIG.colors.text};
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
            z-index: 10000;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            font-size: 16px;
            max-width: 300px;
            cursor: pointer;
            transition: all 0.3s ease;
            animation: slideIn 0.3s ease-out;
        `;
        
        // Add animation keyframes
        if (!document.getElementById('hello-userscript-styles')) {
            const style = document.createElement('style');
            style.id = 'hello-userscript-styles';
            style.textContent = `
                @keyframes slideIn {
                    from {
                        transform: translateX(100%);
                        opacity: 0;
                    }
                    to {
                        transform: translateX(0);
                        opacity: 1;
                    }
                }
                @keyframes slideOut {
                    from {
                        transform: translateX(0);
                        opacity: 1;
                    }
                    to {
                        transform: translateX(100%);
                        opacity: 0;
                    }
                }
            `;
            document.head.appendChild(style);
        }
        
        dialog.innerHTML = `
            <div style="margin-bottom: 10px; font-weight: bold;">
                👋 Onesies Hello!
            </div>
            <div style="margin-bottom: 15px;">
                ${message}
            </div>
            <div style="font-size: 12px; opacity: 0.8;">
                Click to dismiss • Auto-hide in ${CONFIG.timeout/1000}s
            </div>
        `;
        
        // Add to page
        document.body.appendChild(dialog);
        
        // Remove on click
        dialog.addEventListener('click', () => {
            removeDialog(dialog);
        });
        
        // Auto-remove after timeout
        setTimeout(() => {
            if (document.body.contains(dialog)) {
                removeDialog(dialog);
            }
        }, CONFIG.timeout);
        
        // Hover effects
        dialog.addEventListener('mouseenter', () => {
            dialog.style.background = CONFIG.colors.secondary;
            dialog.style.transform = 'scale(1.05)';
        });
        
        dialog.addEventListener('mouseleave', () => {
            dialog.style.background = CONFIG.colors.primary;
            dialog.style.transform = 'scale(1)';
        });
        
        console.log(`👋 ${message}`);
    }
    
    // Remove dialog with animation
    function removeDialog(dialog) {
        dialog.style.animation = 'slideOut 0.3s ease-in';
        setTimeout(() => {
            if (document.body.contains(dialog)) {
                document.body.removeChild(dialog);
            }
        }, 300);
    }
    
    // Interactive greeting function
    function hello(nameOrOptions, options = {}) {
        let finalOptions = {};
        
        if (typeof nameOrOptions === 'string') {
            finalOptions.name = nameOrOptions;
            finalOptions = { ...finalOptions, ...options };
        } else if (typeof nameOrOptions === 'object') {
            finalOptions = nameOrOptions || {};
        }
        
        showGreeting(finalOptions);
    }
    
    // Make hello function available globally
    window.hello = hello;
    
    // Show welcome message
    console.log('✨ Hello userscript ready!');
    console.log('Usage examples:');
    console.log('  hello()                                    // Basic greeting');
    console.log('  hello("Alice")                            // Greet Alice');
    console.log('  hello("Bob", {includeTime: true})         // Greet Bob with time');
    console.log('  hello({name: "Charlie", uppercase: true}) // Greet Charlie in caps');
    
    // Auto-run basic greeting
    setTimeout(() => {
        hello();
    }, 500);
    
})();