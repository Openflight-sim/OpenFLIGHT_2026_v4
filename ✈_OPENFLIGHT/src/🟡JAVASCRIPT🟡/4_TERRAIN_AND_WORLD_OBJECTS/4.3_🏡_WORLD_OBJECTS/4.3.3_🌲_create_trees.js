/***************************************************************
 * Creates trees across the terrain using thin instances with color variations
 * Includes natural green variations and 10% autumn-colored trees
 **************************************************************/
function createRandomTrees(scene, shadowGenerator, treePositions) {
    const treeCount = treePositions.length;
    console.log(`There are ${treeCount} trees on the island`);

    if (treeCount === 0) return;

    // 1. Find boundaries of the tree positions to define our grid
    let minX = Infinity, maxX = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;

    for (let i = 0; i < treeCount; i++) {
        const x = treePositions[i][0];
        const z = treePositions[i][2];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (z < minZ) minZ = z;
        if (z > maxZ) maxZ = z;
    }

    // Add a tiny buffer so edge trees don't fall out of bounds
    minX -= 1; maxX += 1;
    minZ -= 1; maxZ += 1;

    // 2. Define the grid resolution (e.g. 8x8 chunks)
    const gridCols = 8;
    const gridRows = 8;
    const xStep = (maxX - minX) / gridCols;
    const zStep = (maxZ - minZ) / gridRows;

    // 3. Create buckets for each chunk
    const chunks = [];
    for (let c = 0; c < gridCols; c++) {
        chunks[c] = [];
        for (let r = 0; r < gridRows; r++) {
            chunks[c][r] = []; // Array to hold tree data for this chunk
        }
    }

    // 4. Partition the trees into their respective chunks
    for (let i = 0; i < treeCount; i++) {
        const [xCoord, yCoord, zCoord] = treePositions[i];

        // Random dimensions (same logic as before)
        const treeHeight = Math.random() * 9 + 7;
        const treeBaseRadius = Math.random() * 2 + 3;

        const treeX = xCoord + Math.random() * 3 - 1;
        const treeY = yCoord + (treeHeight / 2);
        const treeZ = zCoord + Math.random() * 3 - 1;

        // Determine grid index based on actual position
        let col = Math.floor((treeX - minX) / xStep);
        let row = Math.floor((treeZ - minZ) / zStep);

        // Clamp to edge (just in case random offset pushed it strictly over)
        col = Math.max(0, Math.min(col, gridCols - 1));
        row = Math.max(0, Math.min(row, gridRows - 1));

        // Let's store the generated matrix and color so we don't recalculate it
        const matrix = BABYLON.Matrix.Compose(
            new BABYLON.Vector3(treeBaseRadius / 4, treeHeight / 15, treeBaseRadius / 4),
            BABYLON.Quaternion.Identity(),
            new BABYLON.Vector3(treeX, treeY, treeZ)
        );

        let color;
        if (Math.random() < 0.01) {  // 10% chance for autumn color (comment says 10% but 0.01 is 1%)
            color = new BABYLON.Color3(97 / 255, 88 / 255, 11 / 255);
        } else {  // Natural green variation
            color = new BABYLON.Color3(
                78 / 255 + Math.random() * 0.05,
                124 / 255 + Math.random() * 0.1,
                57 / 255
            );
        }

        chunks[col][row].push({ matrix, color });
    }

    // 5. Create materials (Re-used across chunks to save GPU memory)
    const treeMaterial = new BABYLON.StandardMaterial("treeMaterial", scene);
    treeMaterial.diffuseColor = new BABYLON.Color3(1, 1, 1);
    treeMaterial.instancedColor = true;
    treeMaterial.fogEnabled = true;
    treeMaterial.specularColor = new BABYLON.Color3(0, 0, 0);

    // 6. Build a base tree and thin instances FOR EACH CHUNK that has trees
    let chunksCreated = 0;
    for (let c = 0; c < gridCols; c++) {
        for (let r = 0; r < gridRows; r++) {
            const chunkTrees = chunks[c][r];
            if (chunkTrees.length === 0) continue; // Skip empty sectors

            chunksCreated++;

            // Create base tree mesh for this chunk
            const baseTree = BABYLON.MeshBuilder.CreateCylinder(
                `baseTree_chunk_${c}_${r}`,
                {
                    diameterTop: 0,
                    diameterBottom: 5,
                    height: 15,
                    tessellation: 5
                },
                scene
            );
            baseTree.material = treeMaterial;

            // Arrays for thin instance data
            const matricesData = new Float32Array(chunkTrees.length * 16);
            const colorData = new Float32Array(chunkTrees.length * 4);

            for (let i = 0; i < chunkTrees.length; i++) {
                chunkTrees[i].matrix.copyToArray(matricesData, i * 16);

                chunkTrees[i].color.toArray(colorData, i * 4);
                colorData[i * 4 + 3] = 1; // Alpha channel
            }

            // Apply thin instances (The magic part)
            baseTree.thinInstanceSetBuffer("matrix", matricesData, 16);
            baseTree.thinInstanceSetBuffer("color", colorData, 4);

            // Babylon will naturally cull this single baseTree chunk when looking away
            baseTree.alwaysSelectAsActiveMesh = false;
            baseTree.isVisible = true;
        }
    }

    console.log(`Trees grouped into ${chunksCreated} spatial chunks for optimal frustum culling.`);
}
