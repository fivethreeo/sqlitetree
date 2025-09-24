// API functions - Pure fetch wrappers
export const TreeAPI = {
    async request(url, options = {}) {
        const response = await fetch(url, {
            headers: { 'Content-Type': 'application/json', ...options.headers },
            ...options
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
    },

    getRootNodes() {
        return this.request('/api/trees');
    },

    createTree(name = 'New Tree') {
        return this.request('/api/trees', {
            method: 'POST',
            body: JSON.stringify({ name })
        });
    },

    getTree() {
        return this.request('/api/tree');
    },

    getTreeNodes(treeId) {
        return this.request(`/api/trees/${treeId}/nodes`);
    },

    addNode(treeId, targetNodeId, name, position) {
        return this.request(`/api/trees/${treeId}/nodes`, {
            method: 'POST',
            body: JSON.stringify({ target_node_id: targetNodeId, name, position })
        });
    },

    moveNode(treeId, nodeId, targetNodeId, position) {
        return this.request(`/api/trees/${treeId}/nodes/move`, {
            method: 'POST',
            body: JSON.stringify({ node_id: nodeId, target_node_id: targetNodeId, position })
        });
    }
};