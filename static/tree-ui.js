import { TreeAPI } from '/static/tree-api.js';

class TreeUI {
    constructor() {
        this.treeContainer = $('#tree-container');
        this.treeForm = $('#tree_form').get(0);
        this.apiOutput = $('#api-output');
        this.init();
    }

    init() {
        this.setupEventListeners();
        this.loadTree();
    }

    setupEventListeners() {
        $('#create-tree').on('click', () => this.createTree());
        $('#refresh-tree').on('click', () => this.loadTree());
        $('#expand-all').on('click', () => this.treeContainer.jstree('open_all'));
        $('#collapse-all').on('click', () => this.treeContainer.jstree('close_all'));
    }

    async loadTree() {
        try {
            this.apiOutput.text('Loading tree data...');
            
            const treeData = await TreeAPI.getTree();
            this.apiOutput.text(JSON.stringify(treeData, null, 2));
            
            this.renderTree(treeData);
            
        } catch (error) {
            this.apiOutput.text('Error: ' + error.message);
            console.error('Error loading tree:', error);
        }
    }

    renderTree(treeData) {
        // Convert flat data to nested structure for jsTree
        const jsTreeData = this.convertToJsTreeFormat(treeData);
        
        // Destroy existing tree if it exists
        if (this.treeContainer.jstree(true)) {
            this.treeContainer.jstree('destroy');
        }

        // Initialize jsTree
        this.treeContainer.jstree({
            'core': {
                'data': jsTreeData,
                'check_callback': true,
                'themes': {
                    'responsive': false
                }
            },
            'plugins': ['contextmenu', 'dnd', 'search', 'checkbox'],
            'contextmenu': {
                'items': this.getContextMenuItems.bind(this)
            }
        });

        // Bind events
        this.treeContainer.on('loaded.jstree', () => {
            console.log('Tree loaded successfully');
        });

        this.treeContainer.on('move_node.jstree', (e, data) => {
            this.handleNodeMove(data);
        });
    }

    convertToJsTreeFormat(treeData) {
        // Group nodes by tree_id

        const trees = {};
        treeData.forEach(node => {
            if (!trees[node.tree_id-1]) {
                trees[node.tree_id-1] = [];
            }
            trees[node.tree_id-1].push(node);
        });

        // Convert each tree to hierarchical format
        const result = [];
        
        Object.values(trees).forEach(treeNodes => {
            // Sort by lft for proper hierarchy
            treeNodes.sort((a, b) => a.lft - b.lft);
            
            const nodeMap = {};
            const rootNodes = [];
            
            // Create node map
            treeNodes.forEach(node => {
                nodeMap[node.id] = {
                    id: node.id.toString(),
                    text: `${node.name} (ID: ${node.id}, Tree: ${node.tree_id})`,
                    data: node,
                    children: []
                };
            });
            
            // Build hierarchy
            treeNodes.forEach(node => {
                const currentNode = nodeMap[node.id];
                
                // Find parent (node that contains this node) by level and lft/rgt and smallest rgt-lft difference
                let parent = null;
                for (const potentialParent of treeNodes) {
                    if (potentialParent.level === node.level - 1 &&
                        potentialParent.lft < node.lft &&
                        potentialParent.rgt > node.rgt && potentialParent.tree_id === node.tree_id) {
                        if (!parent || (potentialParent.rgt - potentialParent.lft < parent.rgt - parent.lft)) {
                            parent = potentialParent;
                        }
                    }
                }

                if (parent) {
                    nodeMap[parent.id].children.push(currentNode);
                } else {
                    rootNodes.push(currentNode);
                }
            });
            
            // Add root nodes to result
            result.push(...rootNodes);
        });
        // order by tree_id to keep consistent order
        result.sort((a, b) => a.data.tree_id - b.data.tree_id);
        return result;
    }

    getContextMenuItems(node) {
        const items = {
            'add_child': {
                label: 'Add Child',
                action: () => this.addChildNode(node)
            },
            'rename': {
                label: 'Rename',
                action: () => this.renameNode(node)
            },
            'delete': {
                label: 'Delete',
                action: () => this.deleteNode(node)
            },
            'move': {
                label: 'Move',
                action: () => this.moveNode(node)
            }
        };
        
        return items;
    }

    async addChildNode(node) {
        // Render html5 template from html to hidden imposter div and show it
        const template = document.getElementById('create-node-template');
        const clone = document.importNode(template.content, true);
        const form = clone.querySelector('form');
        const cancelBtn = clone.querySelector('#cancel-create-node');
       const nodeTypeSpan = clone.querySelector('.node-type');
       nodeTypeSpan.textContent = 'Child';

        this.treeForm.innerHTML = '';
        this.treeForm.appendChild(clone);
        this.treeForm.classList.remove('hidden');

        form.addEventListener('submit', async (event) => {
            event.preventDefault();
            const name = form.querySelector('#node-name').value;
            if (name) {
                try {
                    await TreeAPI.addNode(node.data.id, name, 'last-child');
                    await this.loadTree();
                    this.treeForm.innerHTML = '';
                    this.treeForm.classList.add('hidden');

                } catch (error) {
                    alert('Error creating node: ' + error.message);
                }
            }
        });
        cancelBtn.addEventListener('click', () => {
            this.treeForm.innerHTML = '';
            this.treeForm.classList.add('hidden');
        });
    }

    async renameNode(node) {
        const newName = prompt('Enter new name:', node.data.name);
        if (newName && newName !== node.data.name) {
            try {
                await TreeAPI.renameNode(node.data.id, newName);
                await this.loadTree();
            } catch (error) {
                alert('Error renaming node: ' + error.message);
            }
        }
    }

    async deleteNode(node) {
        if (confirm(`Delete "${node.data.name}" and all its children?`)) {
            try {
                await TreeAPI.deleteNode(node.data.id);
                await this.loadTree();
            } catch (error) {
                alert('Error deleting node: ' + error.message);
            }
        }
    }

    async moveNode(node) {
        const targetId = prompt('Enter target node ID:');
        const position = prompt('Position (first-child, last-child, left, right):', 'last-child');
        
        if (targetId && position) {
            try {
                await TreeAPI.moveNode(node.data.id, targetId, position);
                await this.loadTree();
            } catch (error) {
                alert('Error moving node: ' + error.message);
            }
        }
    }

    async handleNodeMove(data) {
        // This handles drag-and-drop moves
        try {
            const nodeId = data.node.id;
            const targetNodeId = data.parent;
            const position = data.position; // index among siblings in target
            console.log(`Moving node ${nodeId} to parent ${targetNodeId} at position ${position}`);
            // Convert jsTree position to our API position
            const apiTargetPosition = this.convertPosition(position, targetNodeId);
            console.log(`Converted position:`, apiTargetPosition);

            await TreeAPI.moveNode(nodeId, apiTargetPosition.id, apiTargetPosition.position);
            await this.loadTree(); // Reload to ensure consistency
            
        } catch (error) {
            alert('Error moving node: ' + error.message);
            this.loadTree(); // Reload to reset tree state
        }
    }

    convertPosition(jsTreePosition, targetNodeId) {
        const tree = this.treeContainer.jstree(true);
        
        if (targetNodeId === '#') {
            // Get nodes in tree_id order
            const rootNodes = tree.get_json('#').sort((a, b) => a.data.tree_id - b.data.tree_id);
            console.log('Root nodes:', rootNodes);
            if (jsTreePosition === 0) {
                return { id: rootNodes[0]?.id || null, position: 'left' };
            } else {
                const siblingId = rootNodes[jsTreePosition]?.id || null;
                return { id: siblingId, position: 'right' };
            }
        } else {
            // Moving to a specific parent node
            const targetNode = tree.get_json(targetNodeId);
            const children = targetNode.children;

            if (jsTreePosition === 0) {
                return { id: targetNodeId, position: 'first-child' };
            } else if (jsTreePosition === children.length) {
                return { id: targetNodeId, position: 'last-child' };
            } else {
                const siblingId = children[jsTreePosition - 1].id;
                return { id: siblingId, position: 'right' };
            }
        }
    }

    async createTree() {
        // Render html5 template from html to hidden imposter div and show it
        const template = document.getElementById('create-node-template');
        const clone = document.importNode(template.content, true);
        const form = clone.querySelector('form');
        const cancelBtn = clone.querySelector('#cancel-create-node');
        const nodeTypeSpan = clone.querySelector('.node-type');
        nodeTypeSpan.textContent = 'Root';

        this.treeForm.innerHTML = '';
        this.treeForm.appendChild(clone);
        this.treeForm.classList.remove('hidden');

        form.addEventListener('submit', async (event) => {
            event.preventDefault();
            const name = form.querySelector('#node-name').value;
            if (name) {
                try {
                    await TreeAPI.createTree(name);
                    await this.loadTree();
                    this.treeForm.innerHTML = '';
                    this.treeForm.classList.add('hidden');

                } catch (error) {
                    alert('Error creating tree: ' + error.message);
                }
            }
        });
        cancelBtn.addEventListener('click', () => {
            this.treeForm.innerHTML = '';
            this.treeForm.classList.add('hidden');
        });
    }
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.treeUI = new TreeUI();
});