import { useState } from "react"
import { Smartphone, Download, Zap, ShieldCheck, Terminal, Camera, Lock, Users, BookOpen, ArrowUpRight } from "lucide-react"
import { useI18n } from "../lib/i18n"
import SpotlightCard from "./reactbits/SpotlightCard"
import TiltedCard from "./reactbits/TiltedCard"
import CommunityModal from "./CommunityModal"

const base = import.meta.env.BASE_URL

const featureIcons = [Smartphone, ShieldCheck, Terminal, Zap, Camera, Lock]

export default function CodeLight() {
  const { t } = useI18n()
  const [communityOpen, setCommunityOpen] = useState(false)

  const features = [1, 2, 3, 4, 5, 6].map((i) => ({
    Icon: featureIcons[i - 1],
    title: t(`codelight.f${i}.title` as any),
    desc: t(`codelight.f${i}.desc` as any),
  }))

  return (
    <section id="codelight" className="relative z-20 bg-deep py-20 sm:py-32 px-4 sm:px-6 noise overflow-hidden">
      <div className="absolute inset-0 bg-[radial-gradient(ellipse_70%_50%_at_50%_0%,rgba(52,211,153,0.06)_0%,transparent_60%)]" />

      <div className="max-w-5xl mx-auto relative z-10">
        {/* Header */}
        <div className="text-center mb-12 sm:mb-16" style={{ animation: 'heroEnter 0.8s ease-out both' }}>
          <div className="flex items-center justify-center gap-2 mb-4">
            <Smartphone size={16} className="text-green" />
            <span className="font-mono text-xs text-green uppercase tracking-[0.3em]">{t("codelight.tag")}</span>
          </div>

          <h2 className="font-mono text-3xl sm:text-5xl font-bold text-text-primary tracking-tight">
            {t("codelight.title")}
          </h2>

          <p className="text-base sm:text-lg text-text-muted mt-4 max-w-lg mx-auto italic">
            "{t("codelight.subtitle")}"
          </p>

          <p className="text-sm text-text-muted mt-4 max-w-xl mx-auto leading-relaxed">
            {t("codelight.desc")}
          </p>

          {/* Free access CTA — prominent, drives to community.
              max-w-2xl (was max-w-lg) so the description fits on one line
              at desktop widths. Second button links out to the Pair iPhone
              setup tutorial. */}
          <div className="mt-8 max-w-2xl mx-auto rounded-2xl p-5 sm:p-6 border border-green/20 bg-green/[0.05]">
            <p className="text-base sm:text-lg font-semibold text-text-primary text-center">
              {t("codelight.freeCta")}
            </p>
            <p className="text-sm text-text-secondary mt-2 text-center leading-relaxed whitespace-normal sm:whitespace-nowrap">
              {t("codelight.freeDesc")}
            </p>
            <div className="flex flex-col sm:flex-row justify-center items-center gap-3 mt-4">
              <button
                onClick={() => setCommunityOpen(true)}
                className="inline-flex items-center gap-2 px-6 py-3 rounded-xl font-bold text-sm bg-green text-deep transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_0_24px_rgba(52,211,153,0.3)] cursor-pointer"
              >
                <Users size={16} />
                {t("community.join")}
              </button>
              <a
                href={`${base}pair-setup.html`}
                className="inline-flex items-center gap-2 px-6 py-3 rounded-xl font-semibold text-sm text-green border border-green/40 bg-green/[0.04] transition-all duration-300 hover:bg-green/[0.12] hover:border-green/60 cursor-pointer"
              >
                <BookOpen size={16} />
                {t("codelight.pairSetupCta")}
                <ArrowUpRight size={14} className="opacity-70" />
              </a>
            </div>
          </div>
        </div>

        {/* v12 hero — iPhone Live Activity, the visual centerpiece of Code Light.
            Placed above the showcase tiles so the section opens with one strong
            real-life proof shot, then drills into individual feature tiles. */}
        <div
          className="mb-12 sm:mb-16 max-w-md mx-auto"
          style={{ animation: 'heroEnter 0.8s ease-out 0.05s both' }}
        >
          <picture>
            <source srcSet={`${base}v12/01-island-macro.webp`} type="image/webp" />
            <img
              src={`${base}v12/01-island-macro.jpg`}
              alt={t("codelight.hero.alt")}
              loading="lazy"
              decoding="async"
              className="block w-full h-auto rounded-3xl shadow-[0_20px_80px_-20px_rgba(52,211,153,0.25)]"
              style={{ aspectRatio: '2 / 3', background: 'var(--color-deep, #0a0b0d)' }}
            />
          </picture>
          <p className="text-center text-sm text-text-muted mt-4 italic">
            {t("codelight.hero.caption")}
          </p>
        </div>

        {/* Showcase - tilted screenshots (v12 4:3 pre-cropped variants) */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-8 mb-16 max-w-3xl mx-auto" style={{ animation: 'heroEnter 0.8s ease-out 0.1s both' }}>
          {[
            { src: `${base}v12/01-island-macro-card.jpg`, webp: `${base}v12/01-island-macro-card.webp`, label: t("codelight.showcase.lockscreen"), alt: t("v12.01.alt") },
            { src: `${base}v12/02-flatlay-desk.jpg`, webp: `${base}v12/02-flatlay-desk.webp`, label: t("codelight.showcase.workflow"), alt: t("v12.02.alt") },
            { src: `${base}v12/03-pairing-card.jpg`, webp: `${base}v12/03-pairing-card.webp`, label: t("codelight.showcase.appstore"), alt: t("v12.03.alt") },
          ].map((img, i) => (
            <TiltedCard
              key={i}
              imageSrc={img.src}
              imageWebpSrc={img.webp}
              altText={img.alt}
              captionText={img.label}
              containerHeight="300px"
              containerWidth="100%"
              imageHeight="280px"
              imageWidth="100%"
              rotateAmplitude={8}
              scaleOnHover={1.04}
              showMobileWarning={false}
              showTooltip={false}
              displayOverlayContent={false}
            />
          ))}
        </div>

        {/* Feature cards grid */}
        <div style={{ animation: 'heroEnter 0.8s ease-out 0.3s both' }}>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4 mb-12">
            {features.map((f, i) => (
              <SpotlightCard
                key={i}
                className="!rounded-2xl !p-5 !bg-green/[0.03] !border-green/[0.12]"
                spotlightColor="rgba(52, 211, 153, 0.2)"
              >
                <div className="w-9 h-9 rounded-xl flex items-center justify-center mb-3" style={{ background: 'rgba(52,211,153,0.15)' }}>
                  <f.Icon size={18} className="text-green" />
                </div>
                <h4 className="text-sm font-bold text-text-primary mb-1">{f.title}</h4>
                <p className="text-xs text-text-muted leading-relaxed">{f.desc}</p>
              </SpotlightCard>
            ))}
          </div>
        </div>

        {/* CTA */}
        <div className="text-center" style={{ animation: 'heroEnter 0.8s ease-out 0.4s both' }}>
          <a
            href="https://apps.apple.com/us/app/code-light/id6761744871"
            className="inline-flex items-center gap-2.5 px-8 py-3.5 rounded-xl font-mono text-sm text-deep font-bold bg-green transition-all duration-300 hover:scale-[1.03] hover:shadow-[0_0_30px_rgba(52,211,153,0.3)]"
          >
            <Download size={16} />
            {t("codelight.appstore")}
          </a>
          <p className="text-sm text-text-muted mt-4">
            {t("codelight.regionNote")}
          </p>
        </div>
      </div>
      <CommunityModal open={communityOpen} onClose={() => setCommunityOpen(false)} />
    </section>
  )
}
