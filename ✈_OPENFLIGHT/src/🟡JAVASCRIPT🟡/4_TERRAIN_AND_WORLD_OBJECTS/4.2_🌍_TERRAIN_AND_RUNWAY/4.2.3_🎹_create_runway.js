/***************************************************************
 * Creates a runway that follows the terrain undulations, but
 * uses a single textured mesh rather than 3D dividers.
 *
 * The texture is generated via a DynamicTexture to look like
 * asphalt, including runway numbers and markers at opposite
 * ends, plus a transition to an earth color at the edges.
 * 
 * Parameters:
 *  - scene: The current Babylon.js scene where the runway is created.
 *  - groundConfig: An object containing the frequency (freqX, freqZ)
 *                  and amplitude properties used to compute terrain
 *                  height at any (x, z). 
 * 
 * Usage:
 *   createRunway(scene, { freqX: 0.01, freqZ: 0.01, amplitude: 2 });
 ***************************************************************/
function createRunway(scene, groundConfig) {
    // Extract frequency config from groundConfig
    const { freqX, freqZ, amplitude } = groundConfig;

    /***************************************************************
     * 1) Create the ground mesh (geometry of the runway)
     ***************************************************************/
    const runway = BABYLON.MeshBuilder.CreateGround(
        "runway",
        {
            // width: Realistic width of the runway (25 m)
            width: 25,
            // height: Realistic length of the runway (1000 m)
            height: 1000,
            // subdivisions: Number of segments for the ground mesh
            subdivisions: 20,
            // updatable: Ensures we can modify vertex data later
            updatable: true
        },
        scene
    )

    runway.physicsImpostor = new BABYLON.PhysicsImpostor(
        runway,
        BABYLON.PhysicsImpostor.MeshImpostor,
        { mass: 0, friction: 0.5 },
        scene
    );




    // Retrieve vertex positions and indices for the runway mesh
    const runwayPositions = runway.getVerticesData(BABYLON.VertexBuffer.PositionKind);
    const runwayIndices = runway.getIndices();

    // Raise the runway to match terrain undulations + a small offset
    for (let v = 0; v < runwayPositions.length; v += 3) {
        // Each vertex has (x, y, z)
        const xCoord = runwayPositions[v];
        const zCoord = runwayPositions[v + 2];

        // Compute the height from your custom undulation map function
        const terrainHeight = compute_terrain_height(xCoord, zCoord, freqX, freqZ, amplitude, scenery_complexity);

        // Slightly above terrain (offset of 0.2)
        runwayPositions[v + 1] = terrainHeight + 0.2 - 7
    }

    // Commit updated positions to the runway mesh
    runway.setVerticesData(BABYLON.VertexBuffer.PositionKind, runwayPositions, true);

    // Recompute normals for correct lighting (since we modified vertex data)
    const runwayNormals = [];
    BABYLON.VertexData.ComputeNormals(runwayPositions, runwayIndices, runwayNormals);
    runway.setVerticesData(BABYLON.VertexBuffer.NormalKind, runwayNormals, true);

    // This code should replace the physics impostor section in function createRunway
    // around line 104 in file 4.2.3_🎹_create_runway.js

    // Enable shadows
    runway.receiveShadows = true;

    // Use BoxImpostor instead of MeshImpostor to fix the warning
    // Create a box impostor that approximates the runway's dimensions
    const runwayPhysicsWidth = 25;    // Same as the runway width
    const runwayPhysicsHeight = 0.4;  // Slightly thicker than the offset (0.2)
    const runwayPhysicsLength = 1000; // Same as the runway length

    runway.physicsImpostor = new BABYLON.PhysicsImpostor(
        runway,
        BABYLON.PhysicsImpostor.BoxImpostor, // Use BoxImpostor instead of MeshImpostor
        {
            mass: 0,
            friction: 0.5,
            restitution: 0.1,
            // You can adjust these dimensions to match your runway
            width: runwayPhysicsWidth,
            height: runwayPhysicsHeight,
            depth: runwayPhysicsLength
        },
        scene
    );


    /***************************************************************
     * 2) Create a DynamicTexture to simulate an asphalt runway
     *    with earth-color edges.
     ***************************************************************/
    // Dimensions of the texture
    const texWidth = 256;   // px
    const texHeight = 4096; // px

    // Create the DynamicTexture
    const runwayTexture = new BABYLON.DynamicTexture(
        "runwayTexture",
        { width: texWidth, height: texHeight },
        scene,
        false  // don't generate mipmaps by default
    );
    const ctx = runwayTexture.getContext();

    // (a) Fill background with a mid-tone gray
    ctx.fillStyle = "#363632";
    ctx.fillRect(0, 0, texWidth, texHeight);

    // (a2) Add subtle color randomness for an "asphalt" look
    const imageData = ctx.getImageData(0, 0, texWidth, texHeight);
    const data = imageData.data;
    for (let i = 0; i < data.length; i += 4) {
        // Each pixel: RGBA
        // Slight random offset to create asphalt speckles
        const offset = Math.random() * 20;
        data[i] += offset; // Red
        data[i + 1] += offset; // Green
        data[i + 2] += offset; // Blue
    }
    ctx.putImageData(imageData, 0, 0);

    // (a3) Blend earth color along the left/right edges
    ctx.save();

    const fadeWidth = 30; // px from each edge, adjust as you like

    // Left side gradient (0 -> fadeWidth)
    const leftGrad = ctx.createLinearGradient(0, 0, fadeWidth, 0);
    leftGrad.addColorStop(0, "#226912");       // earth green/brown
    leftGrad.addColorStop(1, "rgba(0,0,0,0)"); // fade to transparent
    ctx.fillStyle = leftGrad;
    ctx.fillRect(0, 0, fadeWidth, texHeight);

    // Right side gradient (texWidth-fadeWidth -> texWidth)
    const rightGrad = ctx.createLinearGradient(texWidth - fadeWidth, 0, texWidth, 0);
    rightGrad.addColorStop(0, "rgba(0,0,0,0)");
    rightGrad.addColorStop(1, "#226912");
    ctx.fillStyle = rightGrad;
    ctx.fillRect(texWidth - fadeWidth, 0, fadeWidth, texHeight);

    ctx.restore();

    // (a4) Add thin white continuous lines at x = fadeWidth and x = texWidth-fadeWidth
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(fadeWidth, 0);
    ctx.lineTo(fadeWidth, texHeight);
    ctx.moveTo(texWidth - fadeWidth, 0);
    ctx.lineTo(texWidth - fadeWidth, texHeight);
    ctx.strokeStyle = "white";
    ctx.lineWidth = 2;  // thin line
    ctx.stroke();
    ctx.restore();


    /***************************************************************
     * 2b) Draw the runway centerline + markers
     ***************************************************************/

    // (b1) Center dashed line in white.
    ctx.strokeStyle = "white";

    // runway length = 1000 m -> texHeight = 4096 px => ratio ~ 4.096 px/m
    const pxPerMeterY = texHeight / 1000;
    const dashLengthPx = 36.6 * pxPerMeterY; // 36.6 m => ~150 px
    const gapLengthPx = 24.4 * pxPerMeterY; // 24.4 m => ~100 px

    // runway width = 25 m -> texWidth = 256 px => ratio ~ 10.24 px/m
    const pxPerMeterX = texWidth / 25;
    const centerLineWidthPx = 0.91 * pxPerMeterX; // 0.91 m => ~9 px

    function drawDashedLine(x1, y1, x2, y2, dashLength, gapLength) {
        const dx = x2 - x1;
        const dy = y2 - y1;
        const dist = Math.sqrt(dx * dx + dy * dy);
        const dashCount = Math.floor(dist / (dashLength + gapLength)) + 1
        const angle = Math.atan2(dy, dx);

        let x = x1;
        let y = y1;
        for (let i = 0; i < dashCount; i++) {
            // segment start
            const xEnd = x + Math.cos(angle) * dashLength;
            const yEnd = y + Math.sin(angle) * dashLength;
            ctx.beginPath();
            ctx.moveTo(x, y);
            ctx.lineTo(xEnd, yEnd);
            ctx.stroke();
            // move forward by gap
            x = xEnd + Math.cos(angle) * gapLength;
            y = yEnd + Math.sin(angle) * gapLength;
        }
    }

    ctx.lineWidth = centerLineWidthPx;
    const centerX = texWidth / 2
    const margin = 400; // top/bottom margin in pixels
    drawDashedLine(centerX, margin, centerX, texHeight - margin, dashLengthPx, gapLengthPx);

    // --------------------------------------------------------
    // (b2) MOVE THRESHOLD MARKERS to where numbers used to be:
    // --------------------------------------------------------
    //
    // Old numbers were near y=50 (top) and y=texHeight - 50 (bottom).
    // So let's place the 3 marker sets there instead.

    const markerHeight = 70;
    const markerWidth = 10;
    const gapBetweenMarkers = 20;

    // BOTTOM THRESHOLD MARKERS (near y=texHeight - 50)
    const yBottomMarkers = texHeight - 50;
    ctx.fillStyle = "white";
    for (let i = 0; i < 3; i++) {
        // Left side
        const leftX = centerX - 40 - i * gapBetweenMarkers;
        ctx.fillRect(leftX, yBottomMarkers, markerWidth, markerHeight);

        // Right side
        const rightX = centerX + 40 + i * gapBetweenMarkers;
        ctx.fillRect(rightX, yBottomMarkers, markerWidth, markerHeight);
    }

    // TOP THRESHOLD MARKERS (near y=50)
    const yTopMarkers = 50;
    for (let i = 0; i < 3; i++) {
        // Left side
        const leftX = centerX - 40 - i * gapBetweenMarkers;
        ctx.fillRect(leftX, yTopMarkers, markerWidth, markerHeight);

        // Right side
        const rightX = centerX + 40 + i * gapBetweenMarkers;
        ctx.fillRect(rightX, yTopMarkers, markerWidth, markerHeight);
    }

    // --------------------------------------------------------
    // (b3) PLACE RUNWAY NUMBERS where the markers used to be:
    // --------------------------------------------------------
    //
    // Previously, the marker positions were near y=250 (top) and y=texHeight - 300 (bottom).
    // We'll draw "1 8" and "3 6" at these positions now.

    //ctx.font = "120px ICAORWYID"; // ICAO runway font

    ctx.font = "120px 'ICAORWYID', Arial, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = "white";

    // "1 8" at the bottom (was y=texHeight - 300 for markers)
    const yBottomNums = texHeight - 200;
    ctx.fillText(" 1 8", centerX, yBottomNums);

    // "3 6" at the top (was y=250 for markers), rotated 180°
    ctx.save();
    ctx.translate(centerX, 250);
    ctx.rotate(Math.PI);
    ctx.fillText(" 3 6", 0, 0);
    ctx.restore();

    // Commit everything to the dynamic texture
    runwayTexture.update();

    /***************************************************************
     * 3) Apply the DynamicTexture to a material and use on runway
     ***************************************************************/
    const runwayMaterial = new BABYLON.StandardMaterial("runwayMaterial", scene);
    runwayMaterial.diffuseTexture = runwayTexture;

    // Avoid repeating the texture; clamp to edges
    runwayMaterial.diffuseTexture.wrapU = BABYLON.Texture.CLAMP_ADDRESSMODE;
    runwayMaterial.diffuseTexture.wrapV = BABYLON.Texture.CLAMP_ADDRESSMODE;

    // Assign the material to the runway mesh
    runway.material = runwayMaterial;

    /***************************************************************
     * 4) Create High-Fidelity ALSF-2 Approach Lighting System
     ***************************************************************/
    if (typeof scenery_complexity !== 'undefined' && scenery_complexity <= 2) {
        return;
    }

    function createRunwayLightingMode(scene, baseZOffset, directionMultiplier) {
        // Base Materials for Instanced Meshes
        const whiteMat = new BABYLON.StandardMaterial("alsfWhite", scene);
        whiteMat.emissiveColor = new BABYLON.Color3(1, 1, 1);
        whiteMat.disableLighting = true;

        const redMat = new BABYLON.StandardMaterial("alsfRed", scene);
        redMat.emissiveColor = new BABYLON.Color3(1, 0, 0);
        redMat.disableLighting = true;

        const greenMat = new BABYLON.StandardMaterial("alsfGreen", scene);
        greenMat.emissiveColor = new BABYLON.Color3(0, 1, 0);
        greenMat.disableLighting = true;

        // Base Template Meshes (hidden)
        const whiteSphere = BABYLON.MeshBuilder.CreateSphere("whiteTpl", { diameter: 0.4, segments: 4 }, scene);
        whiteSphere.material = whiteMat;
        whiteSphere.isVisible = false;
        whiteSphere.isPickable = false;
        whiteSphere._openFlightGlowLightMarker = true;

        const redSphere = BABYLON.MeshBuilder.CreateSphere("redTpl", { diameter: 0.4, segments: 4 }, scene);
        redSphere.material = redMat;
        redSphere.isVisible = false;
        redSphere.isPickable = false;
        redSphere._openFlightGlowLightMarker = true;

        const greenSphere = BABYLON.MeshBuilder.CreateSphere("greenTpl", { diameter: 0.4, segments: 4 }, scene);
        greenSphere.material = greenMat;
        greenSphere.isVisible = false;
        greenSphere.isPickable = false;
        greenSphere._openFlightGlowLightMarker = true;

        // Add to Glow Layer if enabled
        if (typeof enable_glow_effect !== 'undefined' && enable_glow_effect === true && typeof scenery_complexity !== 'undefined' && scenery_complexity === 4) {
            let glowLayer = typeof window.getOpenFlightSharedGlowLayer === 'function'
                ? window.getOpenFlightSharedGlowLayer(scene, 1.0)
                : scene.getGlowLayerByName("sharedGlowLayer");
            if (!glowLayer) {
                glowLayer = new BABYLON.GlowLayer("sharedGlowLayer", scene, { mainTextureRatio: 0.5 });
                glowLayer.intensity = 1.0;
            }
            if (glowLayer) {
                glowLayer.addIncludedOnlyMesh(whiteSphere);
                glowLayer.addIncludedOnlyMesh(redSphere);
                glowLayer.addIncludedOnlyMesh(greenSphere);
            }
        }

        // Helper function to safely instance and position a light on the terrain
        function placeLight(template, x, z) {
            const inst = template.createInstance("lightInst");
            const groundY = compute_terrain_height(x, z, groundConfig.freqX, groundConfig.freqZ, groundConfig.amplitude, scenery_complexity);
            inst.position = new BABYLON.Vector3(x, groundY + 0.5, z);
            inst.isPickable = false;
            inst._openFlightGlowLightMarker = true;
            return inst;
        }

        const zStart = baseZOffset; // E.g., 500 or -500 (runway ends)
        const dir = directionMultiplier; // 1 for 36, -1 for 18

        // A) Threshold Lights (Green bar across runway width)
        for (let x = -12; x <= 12; x += 1.5) {
            placeLight(greenSphere, x, zStart);
        }

        // B) ALSF-2 Approach System (Extends outward from the runway)
        for (let dist = 30; dist <= 400; dist += 30) {
            const z = zStart + (dist * dir);

            // Centerline white bar (5 lights wide)
            for (let x = -3; x <= 3; x += 1.5) {
                placeLight(whiteSphere, x, z);
            }

            // Red side rows (Inner 300m only)
            if (dist <= 300) {
                for (let x = -9; x <= -4.5; x += 1.5) placeLight(redSphere, x, z); // Left side
                for (let x = 4.5; x <= 9; x += 1.5) placeLight(redSphere, x, z);  // Right side
            }
        }

        // C) Touchdown Zone (TDZ) (Extends inward from the runway)
        for (let dist = 30; dist <= 300; dist += 30) {
            const z = zStart - (dist * dir);
            for (let x = -7.5; x <= -4.5; x += 1.5) placeLight(whiteSphere, x, z); // Left bank
            for (let x = 4.5; x <= 7.5; x += 1.5) placeLight(whiteSphere, x, z);   // Right bank
        }
    }

    // Build ALSF-2 for both ends of the 1000m runway (+500 and -500)
    createRunwayLightingMode(scene, 500, 1);   // Runway 18 end (extending north)
    createRunwayLightingMode(scene, -500, -1); // Runway 36 end (extending south)

    // D) Centerline & Edge Lights (Length of runway)
    const whiteCenterMat = new BABYLON.StandardMaterial("ctrWhite", scene);
    whiteCenterMat.emissiveColor = new BABYLON.Color3(1, 1, 1);
    whiteCenterMat.disableLighting = true;

    const redCenterMat = new BABYLON.StandardMaterial("ctrRed", scene);
    redCenterMat.emissiveColor = new BABYLON.Color3(1, 0, 0);
    redCenterMat.disableLighting = true;

    const ctrWhiteSphere = BABYLON.MeshBuilder.CreateSphere("ctrWhiteTpl", { diameter: 0.3, segments: 4 }, scene);
    ctrWhiteSphere.material = whiteCenterMat;
    ctrWhiteSphere.isVisible = false;
    ctrWhiteSphere.isPickable = false;
    ctrWhiteSphere._openFlightGlowLightMarker = true;

    const ctrRedSphere = BABYLON.MeshBuilder.CreateSphere("ctrRedTpl", { diameter: 0.3, segments: 4 }, scene);
    ctrRedSphere.material = redCenterMat;
    ctrRedSphere.isVisible = false;
    ctrRedSphere.isPickable = false;
    ctrRedSphere._openFlightGlowLightMarker = true;

    if (typeof enable_glow_effect !== 'undefined' && enable_glow_effect === true && typeof scenery_complexity !== 'undefined' && scenery_complexity === 4) {
        let glowLayer = typeof window.getOpenFlightSharedGlowLayer === 'function'
            ? window.getOpenFlightSharedGlowLayer(scene, 1.0)
            : scene.getGlowLayerByName("sharedGlowLayer");
        if (!glowLayer) {
            glowLayer = new BABYLON.GlowLayer("sharedGlowLayer", scene, { mainTextureRatio: 0.5 });
            glowLayer.intensity = 1.0;
        }
        if (glowLayer) {
            glowLayer.addIncludedOnlyMesh(ctrWhiteSphere);
            glowLayer.addIncludedOnlyMesh(ctrRedSphere);
        }
    }

    // From -500 to +500
    for (let z = -485; z <= 485; z += 15) {
        // Edge lights (White)
        const edgeY_L = compute_terrain_height(-12, z, groundConfig.freqX, groundConfig.freqZ, groundConfig.amplitude, scenery_complexity);
        const instEdgeL = ctrWhiteSphere.createInstance("edgeL");
        instEdgeL.position = new BABYLON.Vector3(-12, edgeY_L + 0.3, z);
        instEdgeL.isPickable = false;
        instEdgeL._openFlightGlowLightMarker = true;

        const edgeY_R = compute_terrain_height(12, z, groundConfig.freqX, groundConfig.freqZ, groundConfig.amplitude, scenery_complexity);
        const instEdgeR = ctrWhiteSphere.createInstance("edgeR");
        instEdgeR.position = new BABYLON.Vector3(12, edgeY_R + 0.3, z);
        instEdgeR.isPickable = false;
        instEdgeR._openFlightGlowLightMarker = true;

        // Centerline lights (Alternating White/Red in the last 300m of each end)
        const ctrY = compute_terrain_height(0, z, groundConfig.freqX, groundConfig.freqZ, groundConfig.amplitude, scenery_complexity);
        let ctrColor = ctrWhiteSphere;
        if (Math.abs(z) > 200 && Math.abs(z) <= 500) {
            // Last 300m for either direction
            // Usually alternating red/white or solid red, we'll do alternating for visibility
            if (z % 30 === 0) ctrColor = ctrRedSphere;
        }

        const instCtr = ctrColor.createInstance("ctrLight");
        instCtr.position = new BABYLON.Vector3(0, ctrY + 0.1, z);
        instCtr.isPickable = false;
        instCtr._openFlightGlowLightMarker = true;
    }
}
