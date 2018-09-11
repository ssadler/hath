{-# LANGUAGE FlexibleInstances #-}

module Hath.Data.Misc where

import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX
import Network.Ethereum.Crypto
import Hath.Prelude


magic :: IO String
magic = do
  let t = "\128121\128122\128128\128123\128125\129302\128169\128570\128568\128569\128571\128572\128573\128576\128575\128574\128054\128049\128045\128057\128048\129418\128059\128060\128040\128047\129409\128046\128055\128061\128056\128053\128584\128585\128586\128018\128020\128039\128038\128036\128035\128037\129414\129413\129417\129415\128058\128023\128052\129412\128029\128027\129419\128012\128026\128030\128028\129431\128375\128376\129410\128034\128013\129422\129430\129429\128025\129425\129424\129408\128033\128032\128031\128044\128051\128011\129416\128010\128005\128006\129427\129421\128024\129423\128042\128043\129426\128003\128002\128004\128014\128022\128015\128017\128016\129420\128021\128041\128008\128019\129411\128330\128007\128001\128000\128063\129428\128062\128009\128050\127797\127876\127794\127795\127796\127793\127807\9752\127808\127885\127883\127811\127810\127809\127812\127806\128144\127799\127801\129344\127802\127800\127804\127803\127774\127773\127771\127772\127770\127765\127766\127767\127768\127761\127762\127763\127764\127769\127758\127757\127759\128171\11088\127775\10024\9889\65039\9732\128165\128293\127786\127752\9728\127780\9925\127781\65039\127782\127783\9928\127785\127784\10052\9731\9924\127788\128168\128167\128166\9748\9730\127754\127787\127823\127822\127824\127818\127819\127820\127817\127815\127827\127816\127826\127825\127821\129381\129373\127813\127814\129361\129382\129362\127798\127805\129365\129364\127840\129360\127838\129366\129384\129472\129370\127859\129374\129363\129385\127831\127830\127789\127828\127839\127829\129386\129369\127790\127791\129367\129368\129387\127837\127836\127858\127835\127843\127857\129375\127844\127833\127834\127832\127845\129376\127842\127841\127847\127848\127846\129383\127856\127874\127854\127853\127852\127851\127871\127849\127850\127792\129372\127855\129371\127868\9749\127861\129380\127862\127866\127867\129346\127863\129347\127864\127865\127870\129348\127860\127869\129379\129377\129378\9917\127936\127944\9918\127934\127952\127945\127921\127955\127992\129349\127954\127953\127951\9971\127993\127907\129354\129355\127933\9976\129356\128759\127935\9975\127938\10084\129505\128155\128154\128153\128156\128420\128148\10083\128149\128158\128147\128151\128150\128152\128157"
  day <- round . (/86400) . realToFrac <$> getPOSIXTime
  let ent = sha3' $ fromString $ show day
      s = sum $ map fromIntegral $ BS.unpack ent
      n = mod s (length t)
  pure $ take 1 $ drop n t