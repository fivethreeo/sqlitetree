// Pure API functions - no UI logic
class TreeAPI {
    static async request(url, options = {}) {
        const response = await fetch(url, {
            headers: { 
                'Content-Type': 'application/json', 
                ...options.headers 
            },
            ...options
        });
        
        if (!response.ok) {
            const error = await response.text();
            throw new Error(`HTTP ${response.status}: ${error}`);
        }
        
        return response.json();
    }

    static async getTree() {
        return this.request('/api/tree');
    }

    static async getIndentedTree() {
        return this.request('/api/tree/indented');
    }

    static async getTrees() {
        return this.request('/api/trees');
    }

    static async createTree(name = 'New Tree') {
        return this.request('/api/trees', {
            method: 'POST',
            body: JSON.stringify({ name })
        });
    }

    static async addNode(targetNodeId, name, position = 'last-child') {
        return this.request('/api/nodes', {
            method: 'POST',
            body: JSON.stringify({ target_node_id: targetNodeId, name, position })
        });
    }

    static async moveNode(nodeId, targetNodeId, position = 'last-child') {
        return this.request('/api/nodes/move', {
            method: 'POST',
            body: JSON.stringify({ node_id: nodeId, target_node_id: targetNodeId, position })
        });
    }

    static async deleteNode(nodeId) {
        return this.request(`/api/nodes/${nodeId}`, {
            method: 'DELETE'
        });
    }
}

// Export for use in other modules
window.TreeAPI = TreeAPI;
export { TreeAPI };