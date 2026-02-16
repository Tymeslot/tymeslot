/**
 * Main App Entry Point
 *
 * In multi-bundle mode, this loads the core bundle which initializes LiveSocket.
 * Route-specific bundles (public.js, auth.js, dashboard.js) extend hooks and connect.
 *
 * For pages without a route bundle (e.g., SaaS marketing pages), the layout
 * should include a connection script AFTER app.js that connects with CoreHooks.
 */

// Import core bundle (always loaded)
import "./bundles/core"

// Note: Connection is handled by route bundles or by an inline script in layouts
// that don't use route bundles. This ensures hooks are properly set before connection.
