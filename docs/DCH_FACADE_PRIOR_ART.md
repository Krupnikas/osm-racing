# Facade Extraction — Prior Art & Reusable Components

Survey of existing work for the photo→atom extraction problem (find facade elements,
rectify, segment, make tileable). Conclusion: the three hardest steps each have a
**directly reusable** component — we wire them, we do NOT reinvent the algorithms.

## Directly reusable (code + weights, plug-in) — the important part

| Pipeline step | Reuse | What it is | License | How we use it |
|---|---|---|---|---|
| **Rectification** (de-keystone → orthographic, fixes the up-angle + sideways issue) | **chsasank/Image-Rectification** | Pure-Python classical CV: Canny + probabilistic Hough + RANSAC vanishing points → homography warp. **No weights.** | BSD-3 | Drop `rectification.py` into the pipeline; run on each photo before segmentation. cv2 already installed. |
| **Facade segmentation** (clean window/wall/balcony masks → alpha) | **`Xpitfire/segformer-finetuned-segments-cmp-facade`** (HF) | SegFormer fine-tuned on CMP Facade. 12 classes: facade, molding, cornice, pillar, **window, door, sill, blind, balcony, shop**, deco, background. | (check on HF) | `from transformers import SegformerForSemanticSegmentation` → `from_pretrained(...)`. transformers already installed. Replaces grounding-dino+SAM for facade roles. |
| **Tileable atoms** (seamless wall/window/balcony) | **madaror/tiled-diffusion** (CVPR 2025) or **noise-rolling** | Official tileable-diffusion impl, supports SDXL + ControlNet; or the tiny noise-rolling trick (roll noise each step → model heals the seam). | madaror: check; ComfyUI variant is CC-BY-NC-SA (ok for pet-project) | Wrap our SDXL generation to output horizontally-seamless atoms. |
| **Alpha matting** (clean overlay edges) | `rembg` / Matte Anything | pip-installable background/mask refinement | varied | Refine SAM/SegFormer masks into clean alpha for window/balcony overlays. |

**Caveat on the CMP SegFormer:** CMP is mostly European (Haussmann/varied) facades. It knows
window/balcony/wall/shop (which generalize), but **modern glass curtain walls** may segment imperfectly.
Plan: use it as the drop-in baseline; if glass towers segment poorly, fine-tune on a handful of
annotated DCH crops (CMP-format), or fall back to GroundingDINO+SAM for those.

## The field: "facade parsing"
This exact task (label window/wall/balcony/door on a facade) is a long-standing research area.

**Datasets (reusable for training/fine-tune):**
- **CMP Facade** — 606 annotated imgs; classes incl. window/door/sill/balcony/shop/cornice/molding. (Basis of the drop-in SegFormer above.)
- **ECP** (École Centrale Paris) — 104 rectified Paris facades; window/wall/balcony/door/roof/sky/shop.
- **"Irregular Facades" (MDPI 2024)** — **modern** "free facade" buildings — closest to Gulf glass towers (better fit than CMP/ECP for DCH).
- eTRIMS, RueMonge2014, Graz50.

**Methods / papers:**
- DeepFacade (IJCAI 2017) — deep facade parsing.
- Facade Segmentation in the Wild (arXiv 1805.08634) — unrectified facades + code.
- Improving Facade Parsing with ViT + Line Integration (2023) — exploits the strong window grid; near-SOTA.
- Translational-Symmetry-Aware Facade Parsing (2021) — uses repetition for 3D reconstruction.

**Rectification methods:**
- chsasank/Image-Rectification (the drop-in above).
- Repetition/symmetry-maximization rectification — de-keystone by maximizing facade-grid regularity (ideal for repetitive facades).

**Tiling methods:**
- Tiled Diffusion (CVPR 2025) — seamless tiling for textures/game assets; supports SDXL+ControlNet.
- noise-rolling / circular-padding conv — lightweight seamless tricks (diffusers community).

## Whole-stack analogs (end-to-end "photo → facade on a building")
- **Texture2LoD3 (2025)** — building reconstruction with facade textures from panoramas (LoD3). Closest to our overall goal.
- **Kartta Labs (Google)** — facade reconstruction from photos.
- **OSM 3D renderers** (OSM2World, F4Map, OSMBuildings) — procedural facade textures from `building:levels`/`material` — prior art for OUR runtime side (same idea as FacadeAssembler).
- **Inverse procedural modeling of facades** (shape grammars / Esri CityEngine) — structure-from-image (heavier; not needed for v1).

## Recommended assembly (wire, don't rewrite)
1. **Rectify** each owned photo → orthographic (chsasank RANSAC vanishing points; also fixes orientation).
2. **Segment** with the CMP SegFormer → per-class masks (window/balcony/wall/…); crop + clean alpha.
3. **Generate** per-role atoms by conditioning SDXL (img2img/ControlNet/IP-Adapter) on the clean masked crops; make seamless via tiled-diffusion / noise-rolling; output exact sizes (512/768/1024).
4. (Then runtime selection + render-side so atoms appear in-game.)

## Sources
- Facade Segmentation in the Wild — https://arxiv.org/pdf/1805.08634
- DeepFacade (IJCAI 2017) — https://www.ijcai.org/proceedings/2017/0320.pdf
- ViT + Line Integration facade parsing (2023) — https://arxiv.org/pdf/2309.15523
- Irregular Facades dataset (MDPI 2024) — https://www.mdpi.com/2075-5309/14/9/2602
- CMP SegFormer (drop-in) — https://huggingface.co/Xpitfire/segformer-finetuned-segments-cmp-facade
- chsasank/Image-Rectification (drop-in, BSD-3) — https://github.com/chsasank/Image-Rectification
- Tiled Diffusion (CVPR 2025) — https://github.com/madaror/tiled-diffusion
- Texture2LoD3 (2025) — https://arxiv.org/html/2504.05249v1
