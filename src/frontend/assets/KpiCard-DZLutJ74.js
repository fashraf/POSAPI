import{c as d,j as s,l as c}from"./index-cTC8F_59.js";import{M as u}from"./minus-CMMqSEXu.js";/**
 * @license lucide-react v0.462.0 - ISC
 *
 * This source code is licensed under the ISC license.
 * See the LICENSE file in the root directory of this source tree.
 */const f=d("ArrowDownRight",[["path",{d:"m7 7 10 10",key:"1fmybs"}],["path",{d:"M17 7v10H7",key:"6fjiku"}]]);/**
 * @license lucide-react v0.462.0 - ISC
 *
 * This source code is licensed under the ISC license.
 * See the LICENSE file in the root directory of this source tree.
 */const j=d("ArrowUpRight",[["path",{d:"M7 7h10v10",key:"1tivn9"}],["path",{d:"M7 17 17 7",key:"1vkiza"}]]);function N({label:m,value:o,change:e,changeLabel:a,icon:r,invertTrend:x=!1,className:l}){const i=typeof e=="number"&&Number.isFinite(e),n=i&&Math.abs(e)<5e-4,t=i&&e>0,p=x?!t:t,h=n?u:t?j:f;return s.jsxs("div",{className:c("rounded-lg border border-ink-200 bg-surface p-3.5 shadow-xs",l),children:[s.jsxs("div",{className:"flex items-start justify-between gap-3",children:[s.jsx("p",{className:"text-xs font-medium text-ink-500",children:m}),r&&s.jsx("span",{"aria-hidden":!0,className:"text-ink-300 [&>svg]:h-4 [&>svg]:w-4",children:r})]}),s.jsx("p",{className:"mt-1.5 text-xl font-semibold tracking-tight text-ink-900",children:o}),i&&s.jsxs("div",{className:"mt-2 flex items-center gap-1.5",children:[s.jsxs("span",{className:c("inline-flex items-center gap-0.5 text-sm font-medium",n?"text-ink-500":p?"text-success-600":"text-danger-600"),children:[s.jsx(h,{"aria-hidden":!0,className:"h-3.5 w-3.5"}),s.jsxs("span",{className:"numeric",children:[t&&!n?"+":"",(e*100).toFixed(1),"%"]})]}),a&&s.jsx("span",{className:"text-sm text-ink-400",children:a})]})]})}export{j as A,N as K};
