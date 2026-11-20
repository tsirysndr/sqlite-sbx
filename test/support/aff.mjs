import { runAff_ } from '../../output/Effect.Aff/index.js';
import { Left } from '../../output/Data.Either/index.js';
export const promise = aff => new Promise((resolve, reject) => {
  runAff_(result => () => result instanceof Left ? reject(result.value0) : resolve(result.value0))(aff)();
});
