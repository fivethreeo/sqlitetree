DROP TABLE IF EXISTS tree;
CREATE TABLE tree (
    id INTEGER PRIMARY KEY,
    tree_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    lft INTEGER NOT NULL,
    rgt INTEGER NOT NULL,
    level INTEGER NOT NULL
);

DROP INDEX IF EXISTS idx_tree_tree_id;
DROP INDEX IF EXISTS idx_tree_lft_rgt;
DROP INDEX IF EXISTS idx_tree_name;
CREATE INDEX idx_tree_tree_id ON tree(tree_id);
CREATE INDEX idx_tree_lft_rgt ON tree(lft, rgt);
CREATE INDEX idx_tree_name ON tree(name);

DROP TABLE IF EXISTS add_operation_params;
CREATE TABLE add_operation_params (
    shift_point INTEGER,
    new_level INTEGER,
    tree_id INTEGER
);

DROP TABLE IF EXISTS move_operation_params;
CREATE TABLE move_operation_params (
    node_id INTEGER,
    node_lft INTEGER,
    node_rgt INTEGER,
    node_level INTEGER,
    node_tree_id INTEGER,
    node_width INTEGER,
    node_is_root BOOLEAN,
    target_node_id INTEGER,
    target_lft INTEGER,
    target_rgt INTEGER,
    target_tree_id INTEGER,
    target_level INTEGER,
    target_is_root BOOLEAN,
    move_operation TEXT,
    position TEXT,
    space_target INTEGER,
    level_change INTEGER,
    left_right_change INTEGER,
    right_shift INTEGER
);

DROP TABLE IF EXISTS move_operation_params_log;
CREATE TABLE move_operation_params_log (
    node_id INTEGER,
    node_lft INTEGER,
    node_rgt INTEGER,
    node_level INTEGER,
    node_tree_id INTEGER,
    node_width INTEGER,
    node_is_root BOOLEAN,
    target_node_id INTEGER,
    target_lft INTEGER,
    target_rgt INTEGER,
    target_tree_id INTEGER,
    target_level INTEGER,
    target_is_root BOOLEAN,
    move_operation TEXT,
    position TEXT,
    space_target INTEGER,
    level_change INTEGER,
    left_right_change INTEGER,
    right_shift INTEGER
);

DROP TRIGGER IF EXISTS log_move_operation_params_after_update;
CREATE TRIGGER log_move_operation_params_after_update
AFTER UPDATE ON move_operation_params
BEGIN
    INSERT INTO move_operation_params_log
    SELECT * FROM move_operation_params WHERE rowid = NEW.rowid;
END;

DROP TRIGGER IF EXISTS log_move_operation_params_after_insert;
CREATE TRIGGER log_move_operation_params_after_insert
AFTER INSERT ON move_operation_params
BEGIN
    INSERT INTO move_operation_params_log
    SELECT * FROM move_operation_params WHERE rowid = NEW.rowid;
END;

DROP TABLE IF EXISTS delete_operation_params;
CREATE TABLE delete_operation_params (
    node_size INTEGER,
    node_lft INTEGER,
    node_rgt INTEGER,
    node_tree_id INTEGER,
    node_is_root BOOLEAN
);

DROP TABLE IF EXISTS last_operation_id;
CREATE TABLE last_operation_id (
    id INTEGER,
    operation_name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- Dummy view for update/insert triggers
DROP VIEW IF EXISTS add_root_operation;
CREATE VIEW add_root_operation (name) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS add_root_operation_insert;
CREATE TRIGGER add_root_operation_insert INSTEAD OF INSERT ON add_root_operation
BEGIN
    INSERT INTO tree (tree_id, name, lft, rgt, level)
    WITH max_tree_id AS (
        SELECT IFNULL(MAX(tree_id), 0) + 1 AS new_tree_id FROM tree
    )
    SELECT new_tree_id, NEW.name, 1, 2, 0 FROM max_tree_id;
    INSERT INTO last_operation_id (id, operation_name)
    VALUES (last_insert_rowid(), 'add_root');
END;

DROP VIEW IF EXISTS add_node_operation;
CREATE VIEW add_node_operation (target_node_id, name, position) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS add_node_operation_insert;
CREATE TRIGGER add_node_operation_insert INSTEAD OF INSERT ON add_node_operation
BEGIN
    INSERT INTO add_operation_params (shift_point, new_level, tree_id)
    WITH 
    targ AS (
        SELECT * FROM tree WHERE id = NEW.target_node_id
    ),
    shift AS (
        SELECT
            CASE
                WHEN NEW.position = 'first-child' THEN targ.lft + 1
                WHEN NEW.position = 'last-child' THEN targ.rgt
                WHEN NEW.position = 'left' THEN targ.lft
                WHEN NEW.position = 'right' THEN targ.rgt + 1
                ELSE NULL
            END AS shift_point,
            CASE
                WHEN NEW.position IN ('first-child', 'last-child') THEN targ.level + 1
                WHEN NEW.position IN ('left', 'right') THEN targ.level
                ELSE NULL
            END AS new_level
        FROM targ
    )
    SELECT shift.shift_point, shift.new_level, targ.tree_id FROM shift, targ;

    INSERT INTO create_space_operation ( size, target_point, tree_id)
    SELECT 2, shift_point - 1, tree_id
    FROM add_operation_params;

    INSERT INTO tree (tree_id, name, lft, rgt, level)
    SELECT tree_id, NEW.name, shift_point, shift_point + 1, new_level
    FROM add_operation_params;
    INSERT INTO last_operation_id (id, operation_name)
    VALUES (last_insert_rowid(), 'add_node');
    DELETE FROM add_operation_params;
END;

DROP VIEW IF EXISTS manage_space_operation;
CREATE VIEW manage_space_operation (space, target_point, tree_id) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS manage_space_operation_insert;
CREATE TRIGGER manage_space_operation_insert INSTEAD OF INSERT ON manage_space_operation
BEGIN
    UPDATE tree
    SET lft = CASE
        WHEN lft > NEW.target_point THEN lft + NEW.space
        ELSE lft
    END,
    rgt = CASE
        WHEN rgt > NEW.target_point THEN rgt + NEW.space
        ELSE rgt
    END
    WHERE tree_id = NEW.tree_id AND (lft > NEW.target_point OR rgt > NEW.target_point);
END;



DROP VIEW IF EXISTS move_node_operation;
CREATE VIEW move_node_operation (node_id, target_node_id, position) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS move_node_operation_insert;
CREATE TRIGGER move_node_operation_insert INSTEAD OF INSERT ON move_node_operation
BEGIN
    -- Step 1: Compute move parameters
    INSERT INTO move_operation_params (
        node_id,
        node_lft, node_rgt, node_level, node_tree_id, node_width, node_is_root,
        target_node_id,
        target_lft, target_rgt, target_tree_id, target_level, target_is_root,
        move_operation, position
    )
    WITH
    node_info AS (
        SELECT id, lft, rgt, level, tree_id, rgt - lft + 1 AS width, level = 0 AS is_root_node FROM tree WHERE id = NEW.node_id
    ),
    target_info AS (
        SELECT COALESCE(trg.id, NULL) AS id,
               COALESCE(trg.lft, NULL)   AS lft,
               COALESCE(trg.rgt, NULL)   AS rgt,
               COALESCE(trg.level, NULL) AS level,
               COALESCE(trg.tree_id, NULL) AS tree_id,
               COALESCE(trg.level, NULL) = 0 AS is_root_node
        FROM (SELECT 1) AS dummy
        LEFT JOIN ( 
            SELECT id, lft, rgt, level, tree_id FROM tree WHERE id = NEW.target_node_id
        ) AS trg
    ),
    operation_info AS (
    SELECT 
    CASE 
        WHEN target_info.lft IS NULL THEN
            CASE 
                WHEN NOT node_info.is_root_node
                THEN 'make_child_root_node'
                ELSE NULL  -- target is NULL but node is not child node
            END
        ELSE
            CASE 
                WHEN target_info.is_root_node
                     AND NEW.position IN ('left', 'right') 
                THEN 'make_sibling_of_root_node'
                ELSE
                    CASE 
                        WHEN node_info.is_root_node
                        THEN 'move_root_node'
                        ELSE 'move_child_node'
                    END
            END
    END AS move_operation
    FROM node_info, target_info
    ),
    errors AS (
        SELECT (SELECT
            CASE
                WHEN NEW.position = 'first-child' OR NEW.position = 'last-child' OR NEW.position = 'left' OR NEW.position = 'right' THEN NULL
                ELSE RAISE(ABORT, 'Position must be one of: first-child, last-child, left, right')
            END
            FROM node_info, target_info) AS error_check_position
    )
    SELECT node_info.id,
        node_info.lft AS node_lft, node_info.rgt AS node_rgt, node_info.level AS node_level, node_info.tree_id AS node_tree_id,
        node_info.width AS node_width, node_info.is_root_node AS node_is_root,
        target_info.id,
        target_info.lft AS target_lft, target_info.rgt AS target_rgt, target_info.tree_id AS target_tree_id,target_info.level AS target_level,
        target_info.is_root_node AS target_is_root, operation_info.move_operation AS move_operation, NEW.position AS position
    FROM node_info, target_info, operation_info;

    INSERT INTO make_child_root_node_operation (should_run, new_tree_id)
    SELECT CASE
        WHEN move_operation = 'make_child_root_node' THEN 1
        ELSE 0
    END, NULL
    FROM move_operation_params;

    INSERT INTO make_sibling_of_root_node_operation (should_run)
    SELECT CASE
        WHEN move_operation = 'make_sibling_of_root_node' THEN 1
        ELSE 0
    END
    FROM move_operation_params;

    INSERT INTO move_root_node_operation (should_run)
    SELECT CASE
        WHEN move_operation = 'move_root_node' THEN 1
        ELSE 0
    END
    FROM move_operation_params;

    INSERT INTO move_child_node_operation (should_run)
    SELECT CASE
        WHEN move_operation = 'move_child_node' THEN 1
        ELSE 0
    END
    FROM move_operation_params;
    DELETE FROM move_operation_params;
END;

DROP VIEW IF EXISTS inter_tree_move_and_close_gap_operation;
CREATE VIEW inter_tree_move_and_close_gap_operation (
    level_change, left_right_change, new_tree_id
) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS inter_tree_move_and_close_gap_operation_insert;
CREATE TRIGGER inter_tree_move_and_close_gap_operation_insert 
INSTEAD OF INSERT ON inter_tree_move_and_close_gap_operation
BEGIN
    UPDATE tree
    SET 
        level = CASE
            WHEN lft >= mop.node_lft AND lft <= mop.node_rgt
                THEN level - NEW.level_change
            ELSE level 
        END,
        tree_id = CASE
            WHEN lft >= mop.node_lft AND lft <= mop.node_rgt
                THEN NEW.new_tree_id
            ELSE tree_id 
        END,
        lft = CASE
            WHEN lft >= mop.node_lft AND lft <= mop.node_rgt
                THEN lft - NEW.left_right_change
            WHEN lft > gap.gap_target_left
                THEN lft - gap.gap_size
            ELSE lft 
        END,
        rgt = CASE
            WHEN rgt >= mop.node_lft AND rgt <= mop.node_rgt
                THEN rgt - NEW.left_right_change
            WHEN rgt > gap.gap_target_left
                THEN rgt - gap.gap_size
            ELSE rgt 
        END
    FROM (
        SELECT 
            node_rgt - node_lft + 1 AS gap_size,
            node_lft - 1 AS gap_target_left
        FROM move_operation_params
        LIMIT 1  -- Ensure only one row
    ) AS gap, 
    move_operation_params AS mop
    WHERE tree_id = mop.node_tree_id;
    
END;

DROP VIEW IF EXISTS calculate_inter_tree_move_values_operation;
CREATE VIEW calculate_inter_tree_move_values_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS calculate_inter_tree_move_values_operation_insert;
CREATE TRIGGER calculate_inter_tree_move_values_operation_insert 
INSTEAD OF INSERT ON calculate_inter_tree_move_values_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- Calculate and update move_operation_params with the values
    UPDATE move_operation_params
    SET 
        space_target = CASE 
            WHEN position = 'last-child' THEN target_rgt - 1
            WHEN position = 'first-child' THEN target_lft
            WHEN position = 'left' THEN target_lft - 1
            WHEN position = 'right' THEN target_rgt
            ELSE NULL
        END,
        level_change = CASE 
            WHEN position IN ('last-child', 'first-child') THEN node_level - target_level - 1
            WHEN position IN ('left', 'right') THEN node_level - target_level
            ELSE NULL
        END,
        left_right_change = node_lft - (
            CASE 
                WHEN position = 'last-child' THEN target_rgt - 1
                WHEN position = 'first-child' THEN target_lft
                WHEN position = 'left' THEN target_lft - 1
                WHEN position = 'right' THEN target_rgt
                ELSE NULL
            END
        ) - 1,
        right_shift = CASE WHEN parent_exists THEN 2 * (
            SELECT COUNT(*) FROM tree 
            WHERE tree.lft BETWEEN move_operation_params.node_lft AND move_operation_params.node_rgt
            AND tree.level > move_operation_params.node_level
        ) + 2 ELSE 0 END
    FROM (
        WITH target_parent_check AS (
        SELECT 
            COALESCE(pr.id > 0, 0) AS parent_exists
        FROM (SELECT 1) AS dummy
        LEFT JOIN (
            SELECT parent.id
            FROM tree AS parent, move_operation_params as mop
            JOIN tree AS child ON child.id = mop.target_node_id
            WHERE parent.lft < child.lft
            AND parent.rgt > child.rgt
            ORDER BY (parent.rgt - parent.lft) ASC
            LIMIT 1
        ) AS pr
    ), target_check AS (
        SELECT 
            COALESCE(mop.target_node_id, 0) AS target_exists
        FROM move_operation_params AS mop
    ) SELECT CASE 
        WHEN mop.position IN ('first-child', 'last-child') THEN target_check.target_exists
        WHEN mop.position IN ('left', 'right') THEN target_parent_check.parent_exists
     END AS parent_exists FROM move_operation_params AS mop, target_parent_check, target_check
    ) AS parent
    WHERE move_operation_params.position IN ('first-child', 'last-child', 'left', 'right');
    
END;

DROP VIEW IF EXISTS make_child_root_node_operation;
CREATE VIEW make_child_root_node_operation (should_run, new_tree_id) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS make_child_root_node_operation_insert;
CREATE TRIGGER make_child_root_node_operation_insert 
INSTEAD OF INSERT ON make_child_root_node_operation
BEGIN
    -- Only run if should_run = 1
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- Use the inter_tree_move_and_close_gap_operation with parameters from move_operation_params
    INSERT INTO inter_tree_move_and_close_gap_operation (
        level_change, left_right_change, new_tree_id
    )
    SELECT 
        node_level AS level_change,  -- Reduce level to 0
        node_lft - 1 AS left_right_change,  -- Move to position 1
        (SELECT COALESCE(NEW.new_tree_id, IFNULL(MAX(tree_id), 0) + 1) FROM tree) AS new_tree_id  -- Auto-generate new tree_id
    FROM move_operation_params;
    
END;
DROP VIEW IF EXISTS manage_space_operation;
CREATE VIEW manage_space_operation (space, target_point, tree_id) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS manage_space_operation_insert;
CREATE TRIGGER manage_space_operation_insert 
INSTEAD OF INSERT ON manage_space_operation
BEGIN
    UPDATE tree
    SET 
        lft = CASE
            WHEN lft > NEW.target_point THEN lft + NEW.space
            ELSE lft
        END,
        rgt = CASE
            WHEN rgt > NEW.target_point THEN rgt + NEW.space
            ELSE rgt
        END
    WHERE tree_id = NEW.tree_id 
      AND (lft > NEW.target_point OR rgt > NEW.target_point);
END;

DROP VIEW IF EXISTS close_gap_operation;
CREATE VIEW close_gap_operation (size, target_point, tree_id) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS close_gap_operation_insert;
CREATE TRIGGER close_gap_operation_insert 
INSTEAD OF INSERT ON close_gap_operation
BEGIN
    
    -- Call manage_space_operation with negative size
    INSERT INTO manage_space_operation (space, target_point, tree_id) 
    VALUES (-NEW.size, NEW.target_point, NEW.tree_id);
    
END;

DROP VIEW IF EXISTS create_space_operation;
CREATE VIEW create_space_operation (size, target_point, tree_id) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS create_space_operation_insert;
CREATE TRIGGER create_space_operation_insert 
INSTEAD OF INSERT ON create_space_operation
BEGIN
    
    -- Call manage_space_operation with positive size
    INSERT INTO manage_space_operation (space, target_point, tree_id) 
    VALUES (NEW.size, NEW.target_point, NEW.tree_id);
    
END;

DROP VIEW IF EXISTS create_tree_space_operation;
CREATE VIEW create_tree_space_operation (target_tree_id, num_trees) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS create_tree_space_operation_insert;
CREATE TRIGGER create_tree_space_operation_insert 
INSTEAD OF INSERT ON create_tree_space_operation
BEGIN
    
    -- Increment all tree_ids greater than target_tree_id
    UPDATE tree
    SET tree_id = tree_id + NEW.num_trees
    WHERE tree_id > NEW.target_tree_id;
    
END;

DROP VIEW IF EXISTS make_sibling_of_root_node_operation;
CREATE VIEW make_sibling_of_root_node_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS make_sibling_of_root_node_operation_insert;
CREATE TRIGGER make_sibling_of_root_node_operation_insert 
INSTEAD OF INSERT ON make_sibling_of_root_node_operation
BEGIN
    -- Only run if should_run = 1
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- Handle child node case
    INSERT INTO make_sibling_of_root_node_child_operation (should_run)
    SELECT CASE WHEN NOT node_is_root THEN 1 ELSE 0 END 
    FROM move_operation_params;
    
    -- Handle root node case  
    INSERT INTO make_sibling_of_root_node_root_operation (should_run)
    SELECT CASE WHEN node_is_root THEN 1 ELSE 0 END 
    FROM move_operation_params;
    
END;

-- Child node case
DROP VIEW IF EXISTS make_sibling_of_root_node_child_operation;
CREATE VIEW make_sibling_of_root_node_child_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS make_sibling_of_root_node_child_operation_insert;
CREATE TRIGGER make_sibling_of_root_node_child_operation_insert 
INSTEAD OF INSERT ON make_sibling_of_root_node_child_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- Create tree space
    INSERT INTO create_tree_space_operation (target_tree_id, num_trees)
    SELECT 
        CASE 
            WHEN position = 'left' THEN target_tree_id - 1
            ELSE target_tree_id
        END,
        1
    FROM move_operation_params;
        
    -- Make child node a root
    INSERT INTO make_child_root_node_operation (should_run, new_tree_id)
    SELECT 
        1,
        CASE 
            WHEN position = 'left' THEN target_tree_id
            ELSE target_tree_id + 1
        END
    FROM move_operation_params;
END;

DROP TABLE IF EXISTS logs;

CREATE TABLE logs (
    id INTEGER PRIMARY KEY,
    logtext TEXT NOT NULL
);

-- Root node case  
DROP VIEW IF EXISTS make_sibling_of_root_node_root_operation;
CREATE VIEW make_sibling_of_root_node_root_operation (should_run) AS    
    SELECT NULL WHERE 0;
DROP TRIGGER IF EXISTS make_sibling_of_root_node_root_operation_insert;
CREATE TRIGGER make_sibling_of_root_node_root_operation_insert 
INSTEAD OF INSERT ON make_sibling_of_root_node_root_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;

    UPDATE tree
    SET tree_id = CASE 
        WHEN tree.tree_id = mp.node_tree_id THEN parameters.new_tree_id
        ELSE tree.tree_id + parameters.shift
    END
    FROM move_operation_params AS mp, (
        WITH previous_sibling_info AS (
        SELECT COALESCE(sib.id, 0) AS id, COALESCE(sib.tree_id, 0) AS tree_id

        FROM (SELECT 1) AS dummy
        LEFT JOIN (
            SELECT id, tree_id FROM tree, move_operation_params AS mp WHERE tree_id < mp.target_tree_id AND level = 0 ORDER BY tree_id DESC
            LIMIT 1
        ) AS sib
    ),
    next_sibling_info AS (
        SELECT COALESCE(sib.id, 0) AS id, COALESCE(sib.tree_id, 0) AS tree_id
        FROM (SELECT 1) AS dummy
        LEFT JOIN (
        SELECT id, tree_id FROM tree, move_operation_params AS mp WHERE tree_id > mp.target_tree_id AND level = 0 ORDER BY tree_id ASC
        LIMIT 1
        ) AS sib
    ), params AS (
    SELECT 
        CASE 
        WHEN mp.position = 'left' AND mp.target_tree_id > mp.node_tree_id THEN previous_sibling_info.tree_id
        WHEN mp.position = 'left' AND mp.target_tree_id < mp.node_tree_id THEN mp.target_tree_id
        WHEN mp.position = 'right' AND mp.target_tree_id > mp.node_tree_id THEN mp.target_tree_id
        WHEN mp.position = 'right' AND mp.target_tree_id < mp.node_tree_id THEN next_sibling_info.tree_id
        END AS new_tree_id,
        CASE 
        WHEN mp.position = 'left' AND mp.target_tree_id > mp.node_tree_id THEN -1
        WHEN mp.position = 'left' AND mp.target_tree_id < mp.node_tree_id THEN 1
        WHEN mp.position = 'right' AND mp.target_tree_id > mp.node_tree_id THEN -1
        WHEN mp.position = 'right' AND mp.target_tree_id < mp.node_tree_id THEN 1
        END AS shift
    FROM move_operation_params AS mp, previous_sibling_info, next_sibling_info
    ),
    bounds AS (
    SELECT 
        CASE 
            WHEN mp.position = 'left' AND mp.target_tree_id > mp.node_tree_id THEN mp.node_tree_id
            WHEN mp.position = 'left' AND mp.target_tree_id < mp.node_tree_id THEN params.new_tree_id
            WHEN mp.position = 'right' AND mp.target_tree_id > mp.node_tree_id THEN mp.node_tree_id
            WHEN mp.position = 'right' AND mp.target_tree_id < mp.node_tree_id THEN params.new_tree_id
        END AS lower_bound,
        CASE 
            WHEN mp.position = 'left' AND mp.target_tree_id > mp.node_tree_id THEN params.new_tree_id
            WHEN mp.position = 'left' AND mp.target_tree_id < mp.node_tree_id THEN mp.node_tree_id
            WHEN mp.position = 'right' AND mp.target_tree_id > mp.node_tree_id THEN mp.target_tree_id
            WHEN mp.position = 'right' AND mp.target_tree_id < mp.node_tree_id THEN mp.node_tree_id
        END AS upper_bound
        FROM move_operation_params AS mp, params
    )
    SELECT * FROM bounds, params
    ) AS parameters
    WHERE tree.tree_id BETWEEN parameters.lower_bound AND parameters.upper_bound;
END;

DROP VIEW IF EXISTS move_child_node_operation;
CREATE VIEW move_child_node_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS move_child_node_operation_insert;
CREATE TRIGGER move_child_node_operation_insert
INSTEAD OF INSERT ON move_child_node_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;

    INSERT INTO move_child_within_tree_operation (should_run)
    SELECT node_tree_id = target_tree_id
    FROM move_operation_params;

    INSERT INTO move_child_to_new_tree_operation (should_run)
    SELECT node_tree_id <> target_tree_id
    FROM move_operation_params;

END;

DROP VIEW IF EXISTS move_child_within_tree_operation;
CREATE VIEW move_child_within_tree_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS move_child_within_tree_operation_insert;
CREATE TRIGGER move_child_within_tree_operation_insert 
INSTEAD OF INSERT ON move_child_within_tree_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- Perform the move operation with calculations in FROM clause
    UPDATE tree
    SET 
        level = CASE
            WHEN lft >= mop.node_lft AND lft <= mop.node_rgt
                THEN level - calcs.level_change
            ELSE level
        END,
        lft = CASE
            WHEN lft >= mop.node_lft AND lft <= mop.node_rgt
                THEN lft + calcs.left_right_change
            WHEN lft >= calcs.left_boundary AND lft <= calcs.right_boundary
                THEN lft + calcs.gap_size
            ELSE lft
        END,
        rgt = CASE
            WHEN rgt >= mop.node_lft AND rgt <= mop.node_rgt
                THEN rgt + calcs.left_right_change
            WHEN rgt >= calcs.left_boundary AND rgt <= calcs.right_boundary
                THEN rgt + calcs.gap_size
            ELSE rgt
        END
    FROM 
        move_operation_params AS mop,

        (WITH calc AS (
            SELECT 
                -- Calculate new position based on position type
                CASE 
                    WHEN mop.position = 'last-child' THEN
                        CASE WHEN mop.target_rgt > mop.node_rgt THEN mop.target_rgt - mop.node_width ELSE mop.target_rgt END
                    WHEN mop.position = 'first-child' THEN
                        CASE WHEN mop.target_lft > mop.node_lft THEN mop.target_lft - mop.node_width + 1 ELSE mop.target_lft + 1 END
                    WHEN mop.position = 'left' THEN
                        CASE WHEN mop.target_lft > mop.node_lft THEN mop.target_lft - mop.node_width ELSE mop.target_lft END
                    WHEN mop.position = 'right' THEN
                        CASE WHEN mop.target_rgt > mop.node_rgt THEN mop.target_rgt - mop.node_width + 1 ELSE mop.target_rgt + 1 END
                END AS new_left,
                -- Calculate level change
                CASE 
                    WHEN mop.position IN ('last-child', 'first-child') THEN mop.node_level - mop.target_level - 1
                    ELSE mop.node_level - mop.target_level
                END AS level_change
            FROM move_operation_params AS mop
        )
        SELECT 
            MIN(mop.node_lft, calc.new_left) AS left_boundary,
            MAX(mop.node_rgt, calc.new_left + mop.node_width - 1) AS right_boundary,
            calc.new_left - mop.node_lft AS left_right_change,
            CASE WHEN (calc.new_left - mop.node_lft) > 0 THEN -mop.node_width ELSE mop.node_width END AS gap_size,
            calc.new_left AS new_left,
            calc.level_change AS level_change
            FROM move_operation_params AS mop, calc
        ) AS calcs
    WHERE tree.tree_id = mop.node_tree_id;
    
END;

DROP VIEW IF EXISTS move_child_to_new_tree_operation;
CREATE VIEW move_child_to_new_tree_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS move_child_to_new_tree_operation_insert;
CREATE TRIGGER move_child_to_new_tree_operation_insert 
INSTEAD OF INSERT ON move_child_to_new_tree_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    -- First calculate the inter-tree move values
    INSERT INTO calculate_inter_tree_move_values_operation (should_run) VALUES (1);
    -- Create space for the node in the target tree
    INSERT INTO create_space_operation (size, target_point, tree_id)
    SELECT node_width, space_target, target_tree_id
    FROM move_operation_params;
    -- Move the child node to the target tree
    INSERT INTO inter_tree_move_and_close_gap_operation (
        level_change, left_right_change, new_tree_id
    )
    SELECT 
        level_change, left_right_change, target_tree_id
    FROM move_operation_params;
END;

DROP VIEW IF EXISTS move_root_node_operation;
CREATE VIEW move_root_node_operation (should_run) AS    
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS move_root_node_operation_insert;
CREATE TRIGGER move_root_node_operation_insert 
INSTEAD OF INSERT ON move_root_node_operation
BEGIN
    SELECT CASE WHEN NEW.should_run = 0 THEN RAISE(IGNORE) END;
    
    -- First calculate the inter-tree move values
    INSERT INTO calculate_inter_tree_move_values_operation (should_run) VALUES (1);
    
    -- Create space for the node in the target tree
    INSERT INTO create_space_operation (size, target_point, tree_id)
    SELECT node_width, space_target, target_tree_id
    FROM move_operation_params;
    
    -- Move the root node to the target tree
    UPDATE tree
    SET 
        level = level - mop.level_change,
        lft = lft - mop.left_right_change,
        rgt = rgt - mop.left_right_change,
        tree_id = mop.target_tree_id
    FROM move_operation_params AS mop
    WHERE tree.lft >= mop.node_lft 
      AND tree.lft <= mop.node_rgt
      AND tree.tree_id = mop.node_tree_id;
    -- Close the gap in the original tree by decreasing tree_ids
    UPDATE tree
    SET tree_id = tree_id - 1
    FROM move_operation_params AS mop
    WHERE tree.tree_id > mop.node_tree_id;
END;


DROP VIEW IF EXISTS delete_node_operation;
CREATE VIEW delete_node_operation (node_id) AS
    SELECT NULL WHERE 0;

DROP TRIGGER IF EXISTS delete_node_operation_insert;
CREATE TRIGGER delete_node_operation_insert INSTEAD OF INSERT ON delete_node_operation
BEGIN
    -- Step 1: Compute delete parameters
    INSERT INTO delete_operation_params (node_size, node_lft, node_rgt, node_tree_id, node_is_root)
    WITH 
    node AS (SELECT * FROM tree WHERE id = NEW.node_id)
    SELECT
        node.rgt - node.lft + 1 AS node_size,
        node.lft AS node_lft,
        node.rgt AS node_rgt,
        node.tree_id AS node_tree_id,
        node.level = 0 AS node_is_root
    FROM node;  
    -- Step 2: Delete the node and its subtree
    DELETE FROM tree
    WHERE tree.tree_id = (SELECT node_tree_id FROM delete_operation_params)
      AND tree.lft BETWEEN (SELECT node_lft FROM delete_operation_params)
                      AND (SELECT node_rgt FROM delete_operation_params);


    -- Step 3: Close the gap in the tree
    INSERT INTO close_gap_operation (size, target_point, tree_id)
    SELECT node_size, node_lft, node_tree_id
    FROM delete_operation_params;

    UPDATE tree
    SET tree_id = tree_id - 1
    FROM delete_operation_params AS op
    WHERE op.node_is_root
      AND tree.tree_id > op.node_tree_id;

    DELETE FROM delete_operation_params;
END;

-- Add this view to show indented tree
DROP VIEW IF EXISTS tree_indented;
CREATE VIEW tree_indented AS
WITH tree_with_ancestors AS (
    SELECT 
        t.*,
        (
            SELECT GROUP_CONCAT(a.name, ' > ') 
            FROM tree a 
            WHERE a.tree_id = t.tree_id 
                AND a.lft < t.lft 
                AND a.rgt > t.rgt
            ORDER BY a.tree_id, a.lft
        ) AS ancestor_path,
        (
            SELECT GROUP_CONCAT(a.id, '.') 
            FROM tree a 
            WHERE a.tree_id = t.tree_id 
                AND a.lft < t.lft 
                AND a.rgt > t.rgt
            ORDER BY a.tree_id, a.lft
        ) AS ancestor_id_path,
        (
            SELECT COUNT(*) 
            FROM tree a 
            WHERE a.tree_id = t.tree_id 
                AND a.lft < t.lft 
                AND a.rgt > t.rgt
        ) AS depth
    FROM tree t
)
SELECT 
    id,
    tree_id,
    -- Visual indentation with proper hierarchy markers
    CASE 
        WHEN depth = 0 THEN name
        ELSE 
            SUBSTR('│   │   │   │   │   │   │   │   │   │   ', 1, (depth - 1) * 4) ||
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM tree s 
                    WHERE s.tree_id = tree_id 
                        AND s.lft > lft 
                        AND s.rgt < (
                            SELECT MIN(parent.rgt) 
                            FROM tree parent 
                            WHERE parent.tree_id = tree_id 
                                AND parent.lft < lft 
                                AND parent.rgt > rgt
                            UNION SELECT rgt FROM tree WHERE id = tree_with_ancestors.id
                            LIMIT 1
                        )
                        AND s.level = level + 1
                ) THEN '├── '
                ELSE '└── '
            END || name
    END AS indented_name,
    -- Simple indentation (more reliable)
    SUBSTR('    ', 1, level * 3) || name AS simple_indented_name,
    name,
    lft,
    rgt,
    level,
    COALESCE(ancestor_path || ' > ' || name, name) AS full_path,
    COALESCE(ancestor_id_path || '.' || id, CAST(id AS TEXT)) AS id_path,
    depth
FROM tree_with_ancestors
ORDER BY tree_id, lft;

DROP TABLE IF EXISTS users;
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    is_active BOOLEAN DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

DROP TABLE IF EXISTS registration_tokens;
CREATE TABLE registration_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT UNIQUE NOT NULL,
    user_id INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

DROP TABLE IF EXISTS password_reset_tokens;
CREATE TABLE password_reset_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT UNIQUE NOT NULL,
    user_id INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

DELETE FROM tree;
DELETE FROM last_operation_id;
DELETE FROM add_operation_params;
DELETE FROM move_operation_params;
DELETE FROM delete_operation_params;
-- Create initial tree
insert into add_root_operation (name) values ('Root');

-- Add children
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root'), 'Child 1.1', 'first-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root'), 'Child 1.2', 'last-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Child 1.1'), 'Child 1.1.1', 'first-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Child 1.1'), 'Child 1.1.2', 'last-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Child 1.2'), 'Child 1.2.1', 'first-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Child 1.2'), 'Child 1.2.2', 'last-child');

insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root'), 'Child 1.2.3', 'last-child');

-- add 3 more roots
insert into add_root_operation (name) values ('Root 1');    
insert into add_root_operation (name) values ('Root 2');
insert into add_root_operation (name) values ('Root 3');

-- Add subtrees to new roots
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root 1'), 'Child 2.1', 'first-child');
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root 1'), 'Child 2.2', 'last-child');
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root 2'), 'Child 3.1', 'first-child');
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root 2'), 'Child 3.2', 'last-child');
insert into add_node_operation (target_node_id, name, position) values 
((select id from tree where name = 'Root 3'), 'Child 4.1', 'first-child');

-- Show initial tree structure
SELECT 'Initial tree structure:' as comment;
SELECT name, lft, rgt, level FROM tree ORDER BY tree_id, lft;
insert into delete_node_operation (node_id) values 
((select id from tree where name = 'Root 2'));

-- Show initial tree structure
SELECT 'Post-deletion tree structure:' as comment;
SELECT tree_id, name, lft, rgt, level FROM tree ORDER BY tree_id, lft;
-- Move Child 1.2 to the right of Child 1.1.1
insert into move_node_operation (node_id, target_node_id, position) values 
(
 (select id from tree where name = 'Child 1.2'), 
 (select id from tree where name = 'Child 1.1.1'), 'first-child');

-- Move Root 3 to be the left sibling of Root 1
select id from tree where name = 'Root 1';
select id from tree where name = 'Root 3';
insert into move_node_operation (node_id, target_node_id, position) values 
(
 (select id from tree where name = 'Root 3'), 
 (select id from tree where name = 'Root 1'), 'left');

-- -- Move Child 1.1.1 to be a root node
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Child 1.1.1'), 
 NULL, 'last-child');

---- Move Root 1 to be the right sibling of Child 1.1.2
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Root 1'), 
 (select id from tree where name = 'Child 1.1.2'), 'right');

-- ---- Move Root to be the left sibling of Child 4.1
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Root'), 
 (select id from tree where name = 'Child 4.1'), 'left');

-- ---- Move Root 1 to be the frst child of Child 1.1
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Root 1'), 
 (select id from tree where name = 'Child 1.1'), 'first-child');

-- ---- Move Child 4.1 to be the last child of Root
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Child 4.1'), 
 (select id from tree where name = 'Root'), 'last-child');

-- ---- Move Root to root position
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Root'), 
 NULL, 'last-child');
-- ---- Move Child 1.1 to be the right sibling of Root
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Child 1.1'), 
 (select id from tree where name = 'Root'), 'right');

-- ---- Root 1 to be the right sibling of Child 1.2
insert into move_node_operation (node_id, target_node_id, position) values
(
 (select id from tree where name = 'Root 1'), 
 (select id from tree where name = 'Child 1.2'), 'left');

SELECT 'Indented tree view:' as comment;
SELECT id, tree_id, lft, rgt, level, indented_name FROM tree_indented ORDER BY tree_id, lft;
SELECT * FROM move_operation_params_log;
DELETE FROM move_operation_params_log;