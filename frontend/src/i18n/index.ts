import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

import en from './locales/en/translation.json';
import fa from './locales/fa/translation.json';

const SUPPORTED_LANGUAGES = ['en', 'fa'] as const;

const storedLang = localStorage.getItem('opdesk-lang');

const savedLang = SUPPORTED_LANGUAGES.includes(
  storedLang as (typeof SUPPORTED_LANGUAGES)[number]
)
  ? storedLang!
  : 'fa';

i18n
  .use(initReactI18next)
  .init({
    resources: {
      en: { translation: en },
      fa: { translation: fa },
    },

    // VOIPIRAN: Persian is the default language.
    lng: savedLang,

    fallbackLng: 'en',

    interpolation: {
      escapeValue: false,
    },
  });

/**
 * Persist language choice and update document direction.
 *
 * VOIPIRAN:
 * Persian interface must use RTL direction.
 */
export function setLanguage(lang: string) {
  i18n.changeLanguage(lang);

  localStorage.setItem('opdesk-lang', lang);

  document.documentElement.lang = lang;

  // VOIPIRAN: Persian uses RTL; English uses LTR.
  document.documentElement.dir = lang === 'fa' ? 'rtl' : 'ltr';
}

/**
 * Apply language and direction on initial page load.
 *
 * VOIPIRAN: Persian is the default ContactCenter language.
 */
document.documentElement.lang = savedLang;

// VOIPIRAN: Persian is RTL, English is LTR.
document.documentElement.dir = savedLang === 'fa' ? 'rtl' : 'ltr';

export default i18n;