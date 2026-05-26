#!/usr/bin/env node
// Sharp prebuild — converts source PNGs to optimized WebP + JPG fallbacks.
//
// Sources:
//   ~/Documents/Claude/codex/output_v12/                            (v12 landing assets)
//   ~/Documents/Claude/codex/codelight-image2/screenshots/iphone/   (real iPhone captures)
//   ~/Documents/Claude/codex/codelight-image2/screenshots/mac/      (real Mac captures)
//
// Outputs:
//   landing/public/v12/         (landing imagery)
//   landing/public/pair-setup/  (pair-setup.html tutorial screenshots)

import sharp from 'sharp'
import { mkdir, stat } from 'node:fs/promises'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const __dirname = dirname(fileURLToPath(import.meta.url))
const LANDING_ROOT = resolve(__dirname, '..')

const V12_SRC = join(homedir(), 'Documents/Claude/codex/output_v12')
const IPHONE_SRC = join(homedir(), 'Documents/Claude/codex/codelight-image2/screenshots/iphone')
const MAC_SRC = join(homedir(), 'Documents/Claude/codex/codelight-image2/screenshots/mac')

const V12_OUT = resolve(LANDING_ROOT, 'public/v12')
const PAIR_OUT = resolve(LANDING_ROOT, 'public/pair-setup')

await mkdir(V12_OUT, { recursive: true })
await mkdir(PAIR_OUT, { recursive: true })

const WEBP_QUALITY = 82
const JPG_QUALITY = 86

// iPhone screenshots are 1290×2796 (15 Pro Max). 600px wide is plenty for tutorial use.
const IPHONE_W = 600
// Mac UI captures vary in dimensions. 900px wide keeps text legible without bloat.
const MAC_W = 900

// v12 landing imagery (unchanged from earlier pass)
const v12Jobs = [
  {
    src: '01-island-macro-1024x1536.png',
    outBase: '01-island-macro',
    variants: [
      { name: 'full', transform: (s) => s.resize({ width: 1024, height: 1536, fit: 'cover' }) },
      { name: 'card', transform: (s) => s.resize({ width: 1024, height: 768, fit: 'cover', position: 'top' }) },
    ],
  },
  {
    src: '02-flatlay-desk-1024x1024.png',
    outBase: '02-flatlay-desk',
    variants: [
      { name: 'full', transform: (s) => s.resize({ width: 1024, height: 1024, fit: 'cover' }) },
    ],
  },
  {
    src: '03-pairing-1024x1536.png',
    outBase: '03-pairing',
    variants: [
      { name: 'full', transform: (s) => s.resize({ width: 1024, height: 1536, fit: 'cover' }) },
      { name: 'card', transform: (s) => s.resize({ width: 1024, height: 768, fit: 'cover', position: 'center' }) },
    ],
  },
  {
    src: '04-keynote-trio-1024x1536.png',
    outBase: '04-keynote-trio',
    variants: [
      { name: 'og', transform: (s) => s.resize({ width: 1200, height: 630, fit: 'cover', position: 'top' }), jpgOnly: true },
    ],
  },
]

// Pair-setup tutorial — 9 main steps + 3 bonus / advanced shots
const pairJobs = [
  // Step 0: download both apps (iPhone App Store page)
  { src: 'iphone/IMG_9300.PNG', outBase: 'step0-app-store', w: IPHONE_W },
  // Step 1: Mac → System Settings → CodeLight panel
  { src: 'mac/截屏2026-05-14 10.50.54.png', outBase: 'step1-mac-codelight', w: MAC_W },
  // Step 2: iPhone enters server URL + 6-char pair code
  { src: 'iphone/IMG_9305.PNG', outBase: 'step2-iphone-server', w: IPHONE_W },
  // Step 3 (now part of merged Step 2 in pair-setup.html): Mac shows pairing
  // QR code + 6-char code (redacted by user) + linked devices + redeem input
  { src: 'mac/截屏2026-05-14 10.52.04.png', outBase: 'step3-mac-qr', w: MAC_W },
  // Step 4a: iPhone "scan QR" tab
  { src: 'iphone/IMG_9306.PNG', outBase: 'step4-iphone-scan', w: IPHONE_W },
  // Step 4b: iPhone shows the paired Mac list (handover proof)
  { src: 'iphone/IMG_9301.PNG', outBase: 'step4-iphone-paired', w: IPHONE_W },
  // Step 5a: full Mac desktop with CodeLight, QR window, top notch status
  { src: 'mac/截屏2026-05-14 10.52.21.png', outBase: 'step5-mac-desktop', w: MAC_W },
  // Step 5b: iPhone settings page confirming subscription + token validity
  { src: 'iphone/IMG_9303.PNG', outBase: 'step5-iphone-settings', w: IPHONE_W },
  // Step 5 Hooks (was Step 6): Mac System Settings → cmux 连接 tab — message
  // forwarding link diagnostic (cmux CLI / accessibility / automation perms /
  // Claude session count). Replaces the older 10.50.40 theme-panel placeholder.
  { src: 'mac/微信图片_20260526230943_40348_625.png', outBase: 'step5-cmux-conn', w: MAC_W },
  // Step 7: v12 cafe-OTS — Mac + iPhone synchronized status in real life (composite hero)
  { src: 'v12/05-cafe-ots-1024x1536.png', outBase: 'step7-sync-cafe', w: 900 },
  // "免费持续用" claim flow — promo form + redeem-code success screen
  { src: 'mac/微信图片_20260527073302_40362_625.png', outBase: 'claim-form', w: MAC_W },
  { src: 'mac/微信图片_20260527073302_40361_625.png', outBase: 'claim-success', w: MAC_W },
  // Bonus — launch presets, paywall, redeem success
  { src: 'iphone/IMG_9302.PNG', outBase: 'bonus-launch-presets', w: IPHONE_W },
  { src: 'iphone/IMG_9307.PNG', outBase: 'bonus-paywall', w: IPHONE_W },
  { src: 'mac/截屏2026-05-14 10.52.29.png', outBase: 'bonus-redeem-success', w: MAC_W },
]

function fmtSize(bytes) {
  return `${(bytes / 1024).toFixed(0)} KB`
}

async function processJob({ srcPath, outDir, outBase, variants, simple }) {
  const inSize = (await stat(srcPath)).size
  console.log(`\n📷 ${srcPath.replace(homedir(), '~')}  (${fmtSize(inSize)})`)
  let outBytes = 0

  if (simple) {
    // Simple resize-by-width pair (webp + jpg) for tutorial screenshots
    const { w } = simple
    const webpPath = join(outDir, `${outBase}.webp`)
    const jpgPath = join(outDir, `${outBase}.jpg`)
    await sharp(srcPath).resize({ width: w }).jpeg({ quality: JPG_QUALITY, mozjpeg: true }).toFile(jpgPath)
    await sharp(srcPath).resize({ width: w }).webp({ quality: WEBP_QUALITY }).toFile(webpPath)
    const jpgSize = (await stat(jpgPath)).size
    const webpSize = (await stat(webpPath)).size
    outBytes += jpgSize + webpSize
    console.log(`  → ${outBase}.jpg   ${fmtSize(jpgSize)}`)
    console.log(`  → ${outBase}.webp  ${fmtSize(webpSize)}`)
  } else {
    for (const v of variants) {
      const suffix = v.name === 'full' ? '' : `-${v.name}`
      const webpPath = join(outDir, `${outBase}${suffix}.webp`)
      const jpgPath = join(outDir, `${outBase}${suffix}.jpg`)
      await v.transform(sharp(srcPath)).jpeg({ quality: JPG_QUALITY, mozjpeg: true }).toFile(jpgPath)
      const jpgSize = (await stat(jpgPath)).size
      outBytes += jpgSize
      console.log(`  → ${outBase}${suffix}.jpg   ${fmtSize(jpgSize)}`)
      if (!v.jpgOnly) {
        await v.transform(sharp(srcPath)).webp({ quality: WEBP_QUALITY }).toFile(webpPath)
        const webpSize = (await stat(webpPath)).size
        outBytes += webpSize
        console.log(`  → ${outBase}${suffix}.webp  ${fmtSize(webpSize)}`)
      }
    }
  }
  return { inSize, outBytes }
}

let totalIn = 0
let totalOut = 0

console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
console.log('🎨 v12 landing imagery')
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
for (const job of v12Jobs) {
  const r = await processJob({
    srcPath: join(V12_SRC, job.src),
    outDir: V12_OUT,
    outBase: job.outBase,
    variants: job.variants,
  })
  totalIn += r.inSize
  totalOut += r.outBytes
}

console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
console.log('📱 pair-setup tutorial screenshots')
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
for (const job of pairJobs) {
  let srcPath
  if (job.src.startsWith('iphone/')) {
    srcPath = join(IPHONE_SRC, job.src.replace('iphone/', ''))
  } else if (job.src.startsWith('mac/')) {
    srcPath = join(MAC_SRC, job.src.replace('mac/', ''))
  } else if (job.src.startsWith('v12/')) {
    srcPath = join(V12_SRC, job.src.replace('v12/', ''))
  } else {
    throw new Error(`Unknown source prefix: ${job.src}`)
  }
  const r = await processJob({
    srcPath,
    outDir: PAIR_OUT,
    outBase: job.outBase,
    simple: { w: job.w },
  })
  totalIn += r.inSize
  totalOut += r.outBytes
}

console.log(`\n✅ Done. ${fmtSize(totalIn)} input → ${fmtSize(totalOut)} output`)
console.log(`   ${V12_OUT}`)
console.log(`   ${PAIR_OUT}`)
