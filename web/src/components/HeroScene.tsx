"use client";

import { useEffect, useRef, useState } from "react";
import type { Color as ThreeColor } from "three";

/**
 * A 3D Havaianas-style flip-flop, built from scratch in Three.js.
 * Deliberately not a generic blob or torus knot: the sole outline, the V strap
 * and the little plug are what make the Brazilian reference legible.
 * Falls back to a static SVG poster when WebGL is unavailable.
 */
export function HeroScene() {
  const mountRef = useRef<HTMLDivElement>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let disposed = false;
    let raf = 0;
    let cleanup = () => {};

    (async () => {
      const THREE = await import("three");
      if (disposed || !mountRef.current) return;

      const probe = document.createElement("canvas");
      const gl = probe.getContext("webgl2") ?? probe.getContext("webgl");
      if (!gl) return;

      const mount = mountRef.current;
      const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

      const scene = new THREE.Scene();
      const camera = new THREE.PerspectiveCamera(34, 1, 0.1, 100);
      camera.position.set(0, 0.15, 9.2);

      const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
      renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
      renderer.outputColorSpace = THREE.SRGBColorSpace;
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.12;
      mount.appendChild(renderer.domElement);
      renderer.domElement.style.width = "100%";
      renderer.domElement.style.height = "100%";
      renderer.domElement.style.display = "block";

      // ---------------------------------------------------------------
      // Palette (kept in sync with globals.css)
      // ---------------------------------------------------------------
      const green = new THREE.Color("#0e7a4b");
      const greenDeep = new THREE.Color("#075c37");
      const cream = new THREE.Color("#f6eedf");
      const yellow = new THREE.Color("#f7c948");
      const ocean = new THREE.Color("#1d5fd1");
      const coral = new THREE.Color("#ff5a3c");

      // ---------------------------------------------------------------
      // Sole outline: heel round, waist pinched, toe box wider.
      // ---------------------------------------------------------------
      const soleShape = new THREE.Shape();
      soleShape.moveTo(0, -2.18);
      soleShape.bezierCurveTo(0.98, -2.12, 1.06, -1.32, 0.8, -0.32);
      soleShape.bezierCurveTo(1.16, 0.62, 1.14, 1.56, 0.74, 2.03);
      soleShape.bezierCurveTo(0.44, 2.38, -0.44, 2.38, -0.74, 2.03);
      soleShape.bezierCurveTo(-1.14, 1.56, -1.16, 0.62, -0.8, -0.32);
      soleShape.bezierCurveTo(-1.06, -1.32, -0.98, -2.12, 0, -2.18);

      const extrude = (depth: number, bevel: number) =>
        new THREE.ExtrudeGeometry(soleShape, {
          depth,
          bevelEnabled: true,
          bevelThickness: bevel,
          bevelSize: bevel,
          bevelSegments: 5,
          curveSegments: 28,
        });

      const group = new THREE.Group();
      group.rotation.x = -0.42;
      group.rotation.y = 0.42;
      group.rotation.z = -0.08;

      const matte = (color: ThreeColor, roughness = 0.52) =>
        new THREE.MeshStandardMaterial({ color, roughness, metalness: 0.04 });

      // Base rubber sole.
      const soleGeo = extrude(0.34, 0.06);
      soleGeo.translate(0, 0, -0.17);
      const sole = new THREE.Mesh(soleGeo, matte(greenDeep, 0.62));
      group.add(sole);

      // Thin contrasting side stripe (the classic Havaianas detail).
      const stripeGeo = extrude(0.2, 0.04);
      stripeGeo.scale(1.035, 1.02, 1);
      stripeGeo.translate(0, 0, 0.0);
      const stripe = new THREE.Mesh(stripeGeo, matte(yellow, 0.5));
      group.add(stripe);

      // Insole, slightly inset and lighter.
      const insoleGeo = extrude(0.08, 0.035);
      insoleGeo.scale(0.9, 0.94, 1);
      insoleGeo.translate(0, 0.02, 0.17);
      const insole = new THREE.Mesh(insoleGeo, matte(cream, 0.72));
      group.add(insole);

      // V strap: two tubes meeting at the plug between the toes.
      const strapMat = matte(yellow, 0.4);
      const makeStrap = (side: 1 | -1) => {
        const curve = new THREE.CatmullRomCurve3([
          new THREE.Vector3(side * 0.66, -0.18, 0.2),
          new THREE.Vector3(side * 0.7, 0.22, 0.58),
          new THREE.Vector3(side * 0.38, 0.62, 0.58),
          new THREE.Vector3(0, 0.92, 0.34),
        ]);
        const geo = new THREE.TubeGeometry(curve, 40, 0.085, 10, false);
        return new THREE.Mesh(geo, strapMat);
      };
      group.add(makeStrap(-1), makeStrap(1));

      // Strap plug.
      const plug = new THREE.Mesh(
        new THREE.CylinderGeometry(0.13, 0.13, 0.08, 24),
        matte(cream, 0.35),
      );
      plug.position.set(0, 0.92, 0.36);
      plug.rotation.x = Math.PI / 2;
      group.add(plug);

      // A second, smaller flip-flop floating behind, coral.
      const miniGroup = new THREE.Group();
      const miniSole = new THREE.Mesh(extrude(0.24, 0.05), matte(coral, 0.5));
      miniSole.scale.setScalar(0.46);
      miniGroup.add(miniSole);
      const miniStrap = makeStrap(1).clone();
      miniStrap.scale.setScalar(0.46);
      miniGroup.add(miniStrap);
      const miniStrap2 = makeStrap(-1).clone();
      miniStrap2.scale.setScalar(0.46);
      miniGroup.add(miniStrap2);
      miniGroup.position.set(-2.55, 1.55, -1.8);
      miniGroup.rotation.set(-0.7, 0.7, 0.5);

      // ---------------------------------------------------------------
      // Backdrop: sun disc, orbit ring, particles.
      // ---------------------------------------------------------------
      const sun = new THREE.Mesh(
        new THREE.CircleGeometry(2.55, 64),
        new THREE.MeshBasicMaterial({ color: yellow, transparent: true, opacity: 0.9 }),
      );
      sun.position.set(0.35, 0.15, -2.6);
      scene.add(sun);

      const ring = new THREE.Mesh(
        new THREE.TorusGeometry(2.95, 0.012, 8, 160),
        new THREE.MeshBasicMaterial({ color: ocean, transparent: true, opacity: 0.6 }),
      );
      ring.position.set(0.35, 0.15, -2.4);
      scene.add(ring);

      const dotRing = new THREE.Group();
      const dotGeo = new THREE.SphereGeometry(0.025, 8, 8);
      const dotMat = new THREE.MeshBasicMaterial({ color: green });
      for (let i = 0; i < 54; i += 1) {
        const angle = (i / 54) * Math.PI * 2;
        const dot = new THREE.Mesh(dotGeo, dotMat);
        dot.position.set(Math.cos(angle) * 3.18, Math.sin(angle) * 3.18, -2.3);
        dotRing.add(dot);
      }
      dotRing.position.set(0.35, 0.15, 0);
      scene.add(dotRing);

      const particleCount = 90;
      const positions = new Float32Array(particleCount * 3);
      for (let i = 0; i < particleCount; i += 1) {
        positions[i * 3] = (Math.random() - 0.5) * 10;
        positions[i * 3 + 1] = (Math.random() - 0.5) * 8;
        positions[i * 3 + 2] = (Math.random() - 0.5) * 4 - 1;
      }
      const particleGeo = new THREE.BufferGeometry();
      particleGeo.setAttribute("position", new THREE.BufferAttribute(positions, 3));
      const particles = new THREE.Points(
        particleGeo,
        new THREE.PointsMaterial({
          color: cream,
          size: 0.045,
          transparent: true,
          opacity: 0.85,
          sizeAttenuation: true,
        }),
      );
      scene.add(particles);

      scene.add(group, miniGroup);

      // ---------------------------------------------------------------
      // Lights
      // ---------------------------------------------------------------
      scene.add(new THREE.AmbientLight(0xffffff, 1.35));
      const key = new THREE.DirectionalLight(0xfff3d6, 3.1);
      key.position.set(3.5, 5, 7);
      scene.add(key);
      const fill = new THREE.DirectionalLight(0x9ec4ff, 1.1);
      fill.position.set(-5, -2, 4);
      scene.add(fill);
      const rim = new THREE.PointLight(0xff5a3c, 18, 14, 2);
      rim.position.set(-3.5, 2.5, -3);
      scene.add(rim);

      // ---------------------------------------------------------------
      // Interaction + resize
      // ---------------------------------------------------------------
      const pointer = { x: 0, y: 0 };
      const onPointerMove = (event: PointerEvent) => {
        pointer.x = (event.clientX / window.innerWidth) * 2 - 1;
        pointer.y = (event.clientY / window.innerHeight) * 2 - 1;
      };
      window.addEventListener("pointermove", onPointerMove, { passive: true });

      const resize = () => {
        const rect = mount.getBoundingClientRect();
        const size = Math.max(rect.width, 240);
        renderer.setSize(size, size, false);
        camera.aspect = 1;
        camera.updateProjectionMatrix();
      };
      resize();
      const observer = new ResizeObserver(resize);
      observer.observe(mount);

      // ---------------------------------------------------------------
      // Render loop
      // ---------------------------------------------------------------
      const clock = new THREE.Clock();
      const render = () => {
        const t = clock.getElapsedTime();
        group.rotation.y = 0.42 + Math.sin(t * 0.32) * 0.16 + pointer.x * 0.22;
        group.rotation.x = -0.42 + Math.sin(t * 0.42) * 0.04 - pointer.y * 0.12;
        group.position.y = Math.sin(t * 0.9) * 0.11;

        miniGroup.rotation.y = 0.7 + Math.sin(t * 0.5) * 0.3;
        miniGroup.rotation.z = 0.5 + Math.cos(t * 0.4) * 0.12;
        miniGroup.position.y = 1.55 + Math.sin(t * 0.75 + 1.2) * 0.16;

        ring.rotation.z = t * 0.06;
        dotRing.rotation.z = -t * 0.04;
        particles.rotation.y = t * 0.02;

        renderer.render(scene, camera);
        raf = requestAnimationFrame(render);
      };

      if (reduceMotion) {
        renderer.render(scene, camera);
      } else {
        raf = requestAnimationFrame(render);
      }
      setReady(true);

      cleanup = () => {
        cancelAnimationFrame(raf);
        observer.disconnect();
        window.removeEventListener("pointermove", onPointerMove);
        scene.traverse((object) => {
          if (object instanceof THREE.Mesh || object instanceof THREE.Points) {
            object.geometry.dispose();
            const material = object.material;
            if (Array.isArray(material)) material.forEach((m) => m.dispose());
            else material.dispose();
          }
        });
        renderer.dispose();
        if (renderer.domElement.parentNode === mount) {
          mount.removeChild(renderer.domElement);
        }
      };
    })().catch(() => {
      // WebGL failed after the probe; keep the static poster instead of crashing.
    });

    return () => {
      disposed = true;
      cleanup();
    };
  }, []);

  return (
    <div
      ref={mountRef}
      aria-hidden="true"
      className="relative mx-auto aspect-square w-full max-w-[560px] select-none"
      style={{
        background:
          "radial-gradient(circle at 50% 45%, rgba(247,201,72,0.18), transparent 62%)",
      }}
    >
      {!ready && (
        <div className="absolute inset-0 flex items-center justify-center">
          <svg viewBox="0 0 400 400" className="h-[86%] w-[86%]" role="presentation">
            <circle cx="205" cy="185" r="128" fill="var(--color-sun)" opacity="0.92" />
            <circle
              cx="205"
              cy="185"
              r="150"
              fill="none"
              stroke="var(--color-ocean)"
              strokeWidth="1.5"
              strokeDasharray="3 12"
            />
            <g transform="rotate(-18 200 200)">
              <path
                d="M200 92c42 0 62 24 66 62 3 26-8 62-4 94 5 50-20 96-62 96s-67-46-62-96c4-32-7-68-4-94 4-38 24-62 66-62Z"
                fill="var(--color-tropic)"
              />
              <path
                d="M200 100c36 0 54 21 58 55 2 22-7 54-3 82 4 43-17 83-55 83s-59-40-55-83c4-28-5-60-3-82 4-34 22-55 58-55Z"
                fill="var(--color-sand)"
                opacity="0.92"
              />
              <path
                d="M147 190c20 22 36 30 53 30s33-8 53-30"
                fill="none"
                stroke="var(--color-sun)"
                strokeWidth="16"
                strokeLinecap="round"
              />
              <circle cx="200" cy="218" r="9" fill="var(--color-sand)" />
              <circle cx="200" cy="218" r="4" fill="var(--color-tropic)" />
            </g>
          </svg>
        </div>
      )}
    </div>
  );
}
