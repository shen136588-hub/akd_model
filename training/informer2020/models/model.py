import torch
import torch.nn as nn
import torch.nn.functional as F

from utils.masking import TriangularCausalMask, ProbMask
from models.encoder import Encoder, EncoderLayer, ConvLayer, EncoderStack
from models.decoder import Decoder, DecoderLayer
from models.classifier import TimeSeriesClassifier
from models.attn import FullAttention, ProbAttention, AttentionLayer
from models.embed import DataEmbedding

class Informer(nn.Module):
    def __init__(self, enc_in, dec_in, c_out, seq_len, label_len, out_len, 
                factor=5, d_model=512, n_heads=8, e_layers=3, d_layers=2, d_ff=512, 
                dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu', 
                output_attention = False, distil=True, mix=True,
                device=torch.device('cuda:0')):
        super(Informer, self).__init__()
        self.pred_len = out_len
        self.attn = attn
        self.output_attention = output_attention

        # Encoding
        self.enc_embedding = DataEmbedding(enc_in, d_model, embed, freq, dropout)
        self.dec_embedding = DataEmbedding(dec_in, d_model, embed, freq, dropout)
        # Attention
        Attn = ProbAttention if attn=='prob' else FullAttention
        # Encoder
        self.encoder = Encoder(
            [
                EncoderLayer(
                    AttentionLayer(Attn(False, factor, attention_dropout=dropout, output_attention=output_attention), 
                                d_model, n_heads, mix=False),
                    d_model,
                    d_ff,
                    dropout=dropout,
                    activation=activation
                ) for l in range(e_layers)
            ],
            [
                ConvLayer(
                    d_model
                ) for l in range(e_layers-1)
            ] if distil else None,
            norm_layer=torch.nn.LayerNorm(d_model)
        )
        # Decoder
        self.decoder = Decoder(
            [
                DecoderLayer(
                    AttentionLayer(Attn(True, factor, attention_dropout=dropout, output_attention=False), 
                                d_model, n_heads, mix=mix),
                    AttentionLayer(FullAttention(False, factor, attention_dropout=dropout, output_attention=False), 
                                d_model, n_heads, mix=False),
                    d_model,
                    d_ff,
                    dropout=dropout,
                    activation=activation,
                )
                for l in range(d_layers)
            ],
            norm_layer=torch.nn.LayerNorm(d_model)
        )
        # self.end_conv1 = nn.Conv1d(in_channels=label_len+out_len, out_channels=out_len, kernel_size=1, bias=True)
        # self.end_conv2 = nn.Conv1d(in_channels=d_model, out_channels=c_out, kernel_size=1, bias=True)
        self.projection = nn.Linear(d_model, c_out, bias=True)
        
    def forward(self, x_enc, x_mark_enc, x_dec, x_mark_dec, 
                enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        enc_out = self.enc_embedding(x_enc, x_mark_enc)
        enc_out, attns = self.encoder(enc_out, attn_mask=enc_self_mask)

        dec_out = self.dec_embedding(x_dec, x_mark_dec)
        dec_out = self.decoder(dec_out, enc_out, x_mask=dec_self_mask, cross_mask=dec_enc_mask)
        dec_out = self.projection(dec_out)
        
        # dec_out = self.end_conv1(dec_out)
        # dec_out = self.end_conv2(dec_out.transpose(2,1)).transpose(1,2)
        if self.output_attention:
            return dec_out[:,-self.pred_len:,:], attns
        else:
            return dec_out[:,-self.pred_len:,:] # [B, L, D]



class InformerEncoderOnly(nn.Module):
    """仅包含 Embedding 和 Encoder 的 Informer 变体"""
    
    def __init__(self, enc_in, d_model=512, n_heads=8, e_layers=3, d_ff=512,
                 dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                 output_attention=False, distil=True, mix=False,
                 device=torch.device('cuda:0')):
        super(InformerEncoderOnly, self).__init__()
        
        self.attn = attn
        self.output_attention = output_attention
        
        # Encoding
        self.enc_embedding = DataEmbedding(enc_in, d_model, embed, freq, dropout)
        
        # Attention
        Attn = ProbAttention if attn == 'prob' else FullAttention
        
        # Encoder
        self.encoder = Encoder(
            [
                EncoderLayer(
                    AttentionLayer(Attn(False, factor=5, attention_dropout=dropout, output_attention=output_attention), 
                                d_model, n_heads, mix=False),
                    d_model,
                    d_ff,
                    dropout=dropout,
                    activation=activation
                ) for l in range(e_layers)
            ],
            [
                ConvLayer(
                    d_model
                ) for l in range(e_layers - 1)
            ] if distil else None,
            norm_layer=torch.nn.LayerNorm(d_model)
        )
        
        # 保存参数
        self.d_model = d_model
    
    def forward(self, x_enc, x_mark_enc, enc_self_mask=None):
        """
        前向传播（仅使用编码器）
        
        Args:
            x_enc: 编码器输入 [batch_size, seq_len, enc_in]
            x_mark_enc: 编码器时间标记 [batch_size, seq_len, time_features]
            enc_self_mask: 编码器自注意力掩码
        
        Returns:
            encoder_output: 编码器输出 [batch_size, seq_len, d_model]
            attns: 注意力权重（如果output_attention=True）
        """
        # 嵌入层
        enc_out = self.enc_embedding(x_enc, x_mark_enc)
        
        # 编码器
        enc_out, attns = self.encoder(enc_out, attn_mask=enc_self_mask)
        
        if self.output_attention:
            return enc_out, attns
        else:
            return enc_out
class InformerEncoderOnlyMask(nn.Module):
    """仅包含 Embedding 和 Encoder 的 Informer 变体"""
    
    def __init__(self, enc_in, d_model=512, n_heads=8, e_layers=3, d_ff=512,
                 dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                 output_attention=False, distil=True, mix=False,
                 device=torch.device('cuda:0')):
        super(InformerEncoderOnlyMask, self).__init__()
        
        self.attn = attn
        self.output_attention = output_attention
        
        # Encoding
        self.enc_embedding = DataEmbedding(enc_in, d_model, embed, freq, dropout)
        
        # Attention
        Attn = ProbAttention if attn == 'prob' else FullAttention
        
        # Encoder
        self.encoder = Encoder(
            [
                EncoderLayer(
                    AttentionLayer(Attn(False, factor=5, attention_dropout=dropout, output_attention=output_attention), 
                                d_model, n_heads, mix=False),
                    d_model,
                    d_ff,
                    dropout=dropout,
                    activation=activation
                ) for l in range(e_layers)
            ],
            [
                ConvLayer(
                    d_model
                ) for l in range(e_layers - 1)
            ] if distil else None,
            norm_layer=torch.nn.LayerNorm(d_model)
        )
        
        # 保存参数
        self.d_model = d_model
    
    def forward(self, x_enc, x_mark_enc, mask):
        """
        前向传播（仅使用编码器）
        
        Args:
            x_enc: 编码器输入 [batch_size, seq_len, enc_in]
            x_mark_enc: 编码器时间标记 [batch_size, seq_len, time_features]
            mask: 编码器自注意力掩码
        
        Returns:
            encoder_output: 编码器输出 [batch_size, seq_len, d_model]
            attns: 注意力权重（如果output_attention=True）
        """
        # 嵌入层
        enc_out = self.enc_embedding(x_enc, x_mark_enc)
        if mask is not None:
            # mask: [batch_size, seq_len]
            # 扩展为 [batch_size, seq_len, 1] 然后广播到 [batch_size, seq_len, d_model]
            enc_out = enc_out * mask.unsqueeze(-1)
        #创建attn_mask
        attn_mask = None
        if mask is not None:
            attn_mask = self._create_attention_mask(mask)
        # 编码器
        enc_out, attns = self.encoder(enc_out, attn_mask= attn_mask)
        
        if self.output_attention:
            return enc_out, attns
        else:
            return enc_out

    def _create_attention_mask(self, mask):
        """
        创建注意力mask
        mask: [batch, seq_len] (1=真实，0=填充)
        返回: [batch, seq_len, seq_len] (True=掩蔽，False=可见)
        """
        batch_size, seq_len = mask.shape
        
        # 扩展为[batch, seq_len, seq_len]
        mask_expanded = mask.unsqueeze(1)  # [batch, 1, seq_len]
        mask_expanded = mask_expanded.expand(-1, seq_len, -1)  # [batch, seq_len, seq_len]
        
        # 创建注意力mask
        # 如果任意一方是填充位置，则掩蔽该注意力
        attn_mask = ~(mask_expanded.bool())
        
        return attn_mask
            
class InformerWithClassifier(nn.Module):
    """集成Informer和分类器的完整模型"""
    
    def __init__(self, enc_in, dec_in, c_out, seq_len, label_len, out_len,
                 factor=5, d_model=512, n_heads=8, e_layers=3, d_layers=2, d_ff=512,
                 dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                 output_attention=False, distil=True, mix=True,
                 classifier_type='global_avg',  # 'last_step' 或 'global_avg'
                 classifier_hidden_dims=[128, 64], classifier_dropout_rates=[0.3, 0.2],
                 num_classes=2,  # 2 for binary classification
                 device=torch.device('cuda:0')):
        """
        初始化带分类器的Informer模型
        
        Args:
            前18个参数与Informer相同
            classifier_type: 特征提取方式，'last_step'或'global_avg'
            classifier_hidden_dims: 分类器隐藏层维度
            classifier_dropout_rates: 分类器dropout比率
            num_classes: 分类数量
        """
        super(InformerWithClassifier, self).__init__()
        
        # 创建Informer基础模型
        self.informer = Informer(
            enc_in, dec_in, c_out, seq_len, label_len, out_len,
            factor, d_model, n_heads, e_layers, d_layers, d_ff,
            dropout, attn, embed, freq, activation,
            output_attention, distil, mix, device
        )
        
        #self.classifier_type = classifier_type
        #self.num_classes = num_classes
        self.output_attention = output_attention
        
        # 确定分类器输入维度
        classifier_input_dim = d_model  # 使用Informer的d_model作为特征维度
        
        # 创建分类器
        self.classifier = TimeSeriesClassifier(
            input_dim=classifier_input_dim,
            classifier_type=classifier_type,
            hidden_dims=classifier_hidden_dims,
            dropout_rates=classifier_dropout_rates,
            num_classes=num_classes
        )
        
        # 保存参数以便访问
        self.d_model = d_model
        self.pred_len = out_len
        self.c_out = c_out
        
    def forward(self, x_enc, x_mark_enc, x_dec, x_mark_dec,
                enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        """
        前向传播
        
        Returns:
            如果是分类任务：返回分类logits [batch_size] (二分类) 或 [batch_size, num_classes] (多分类)
            注意：如果output_attention=True，返回 (logits, attention_weights)
        """
        # 通过Informer获取输出
        if self.output_attention:
            informer_output, attns = self.informer(
                x_enc, x_mark_enc, x_dec, x_mark_dec,
                enc_self_mask, dec_self_mask, dec_enc_mask
            )
        else:
            informer_output = self.informer(
                x_enc, x_mark_enc, x_dec, x_mark_dec,
                enc_self_mask, dec_self_mask, dec_enc_mask
            )
            attns = None
        
        # 通过分类器
        logits = self.classifier(informer_output)
        
        if self.output_attention:
            return logits, attns
        else:
            return logits
    
    def extract_features(self, x_enc, x_mark_enc, x_dec, x_mark_dec,
                         enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        """
        提取特征（不进行分类）
        
        Args:
            同forward参数
        
        Returns:
            提取的特征 [batch_size, seq_len, d_model]
        """
        # 通过Informer获取输出
        informer_output = self.informer(
            x_enc, x_mark_enc, x_dec, x_mark_dec,
            enc_self_mask, dec_self_mask, dec_enc_mask
        )
        
        # 根据分类器类型提取特征
        if self.classifier_type == 'last_step':
            features = informer_output[:, -1, :]  # [batch_size, d_model]
        elif self.classifier_type == 'global_avg':
            features = informer_output.mean(dim=1)  # [batch_size, d_model]
        else:
            # 默认返回原始特征
            features = informer_output
        
        return features
    
    def predict_proba(self, x_enc, x_mark_enc, x_dec, x_mark_dec,
                      enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        """
        预测概率（仅用于分类任务）
        
        Args:
            同forward参数
        
        Returns:
            预测概率 [batch_size] (二分类) 或 [batch_size, num_classes] (多分类)
        """
        logits = self.forward(x_enc, x_mark_enc, x_dec, x_mark_dec,
                              enc_self_mask, dec_self_mask, dec_enc_mask)
        
        # 处理可能的元组返回（当output_attention=True时）
        if isinstance(logits, tuple):
            logits = logits[0]
        
        if self.num_classes == 2:
            # 二分类：使用sigmoid
            probabilities = torch.sigmoid(logits)
            return probabilities
        else:
            # 多分类：使用softmax
            probabilities = F.softmax(logits, dim=-1)
            return probabilities
    
    def predict_class(self, x_enc, x_mark_enc, x_dec, x_mark_dec,
                      enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None,
                      threshold=0.5):
        """
        预测类别（仅用于分类任务）
        
        Args:
            threshold: 二分类时的阈值
        
        Returns:
            预测类别
        """
        probabilities = self.predict_proba(x_enc, x_mark_enc, x_dec, x_mark_dec,
                                           enc_self_mask, dec_self_mask, dec_enc_mask)
        
        if self.num_classes == 2:
            # 二分类
            predictions = (probabilities > threshold).long()
            return predictions
        else:
            # 多分类
            predictions = torch.argmax(probabilities, dim=-1)
            return predictions
    
    def get_model_components(self):
        """
        获取模型组件
        
        Returns:
            包含模型组件的字典
        """
        return {
            'informer': self.informer,
            'classifier': self.classifier,
            'classifier_type': self.classifier_type,
            'num_classes': self.num_classes
        }


class InformerEncodeWithClassifier(nn.Module):
    """使用 Informer 的 Encoder 部分进行分类的模型"""
    
    def __init__(self, enc_in, d_model=512, n_heads=4, e_layers=3, d_ff=1024,
                 dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                 output_attention=False, distil=True,mix=False,
                 classifier_type='global_avg',  # 'last_step', 'global_avg', 'flatten'
                 classifier_hidden_dims=[256, 512], classifier_dropout_rates=[0.35, 0.35],
                 num_classes=2,  # 2 for binary classification
                 device=torch.device('cuda:0')):
        """
        初始化分类器模型
        
        Args:
            enc_in: 输入特征维度
            d_model: 模型维度
            n_heads: 注意力头数
            e_layers: 编码器层数
            d_ff: 前馈网络维度
            dropout: dropout比率
            attn: 注意力类型 ('prob' 或 'full')
            embed: 嵌入类型
            freq: 时间频率
            activation: 激活函数
            output_attention: 是否输出注意力权重
            distil: 是否使用蒸馏
            classifier_type: 分类器类型
            classifier_hidden_dims: 分类器隐藏层维度
            classifier_dropout_rates: 分类器dropout比率
            num_classes: 分类数量
        """
        super(InformerEncodeWithClassifier, self).__init__()
        
        # 创建仅包含 Encoder 的 Informer
        self.encoder = InformerEncoderOnly(
            enc_in=enc_in,
            d_model=d_model,
            n_heads=n_heads,
            e_layers=e_layers,
            d_ff=d_ff,
            dropout=dropout,
            attn=attn,
            embed=embed,
            freq=freq,
            activation=activation,
            output_attention=output_attention,
            distil=distil,
            mix=False,
            device=device
        )
        
        #self.classifier_type = classifier_type
        #self.num_classes = num_classes
        self.output_attention = output_attention
        #self.d_model = d_model

        classifier_input_dim = d_model 
        
        # 创建分类器
        self.classifier = TimeSeriesClassifier(
            input_dim=classifier_input_dim,
            classifier_type=classifier_type,
            hidden_dims=classifier_hidden_dims,
            dropout_rates=classifier_dropout_rates,
            num_classes=num_classes
        )
    
    def forward(self, x_enc, x_mark_enc, x_dec=None, x_mark_dec=None, 
                enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        """
        前向传播 - 兼容版本
        
        Args:
            x_enc: 输入序列 [batch_size, seq_len, enc_in]
            x_mark_enc: 时间标记 [batch_size, seq_len, time_features]
            x_dec: decoder输入（忽略，为了兼容性）
            x_mark_dec: decoder时间标记（忽略，为了兼容性）
            enc_self_mask: 注意力掩码
        
        Returns:
            分类结果
        """
        # 通过编码器
        if self.output_attention:
            encoder_output, attns = self.encoder(x_enc, x_mark_enc, enc_self_mask)
        else:
            encoder_output = self.encoder(x_enc, x_mark_enc, enc_self_mask)
            attns = None
        
        # 通过分类器
        logits = self.classifier(encoder_output)
        
        if self.output_attention:
            return logits, attns
        else:
            return logits
    
    def extract_features(self, x_enc, x_mark_enc, enc_self_mask=None):
        """
        提取编码器特征
        """
        encoder_output = self.encoder(x_enc, x_mark_enc, enc_self_mask)
        return encoder_output
    
    def predict_proba(self, x_enc, x_mark_enc, enc_self_mask=None):
        """
        预测概率
        """
        logits = self.forward(x_enc, x_mark_enc, enc_self_mask)
        
        # 处理可能的元组返回
        if isinstance(logits, tuple):
            logits = logits[0]
        
        if self.num_classes == 2:
            probabilities = torch.sigmoid(logits)
        else:
            probabilities = F.softmax(logits, dim=-1)
        
        return probabilities
    
    def predict_class(self, x_enc, x_mark_enc, enc_self_mask=None, threshold=0.5):
        """
        预测类别
        """
        probabilities = self.predict_proba(x_enc, x_mark_enc, enc_self_mask)
        
        if self.num_classes == 2:
            predictions = (probabilities > threshold).long()
        else:
            predictions = torch.argmax(probabilities, dim=-1)
        
        return predictions


class InformerEncodeMaskWithClassifier(nn.Module):
    """使用 Informer 的 Encoder 部分进行分类的模型"""
    
    def __init__(self, enc_in, d_model=512, n_heads=8, e_layers=3, d_ff=512,
                 dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                 output_attention=False, distil=True,mix=False,
                 classifier_type='last_step',  # 'last_step', 'global_avg', 'flatten'
                 classifier_hidden_dims=[128, 64], classifier_dropout_rates=[0.3, 0.2],
                 num_classes=2,  # 2 for binary classification
                 device=torch.device('cuda:0')):
        """
        初始化分类器模型
        
        Args:
            enc_in: 输入特征维度
            d_model: 模型维度
            n_heads: 注意力头数
            e_layers: 编码器层数
            d_ff: 前馈网络维度
            dropout: dropout比率
            attn: 注意力类型 ('prob' 或 'full')
            embed: 嵌入类型
            freq: 时间频率
            activation: 激活函数
            output_attention: 是否输出注意力权重
            distil: 是否使用蒸馏
            classifier_type: 分类器类型
            classifier_hidden_dims: 分类器隐藏层维度
            classifier_dropout_rates: 分类器dropout比率
            num_classes: 分类数量
        """
        super(InformerEncodeMaskWithClassifier, self).__init__()
        
        # 创建仅包含 Encoder 的 Informer
        self.encoder = InformerEncoderOnlyMask(
            enc_in=enc_in,
            d_model=d_model,
            n_heads=n_heads,
            e_layers=e_layers,
            d_ff=d_ff,
            dropout=dropout,
            attn=attn,
            embed=embed,
            freq=freq,
            activation=activation,
            output_attention=output_attention,
            distil=distil,
            mix=False,
            device=device
        )
        
        #self.classifier_type = classifier_type
        #self.num_classes = num_classes
        self.output_attention = output_attention
        #self.d_model = d_model

        classifier_input_dim = d_model 
        
        # 创建分类器
        self.classifier = TimeSeriesClassifier(
            input_dim=classifier_input_dim,
            classifier_type=classifier_type,
            hidden_dims=classifier_hidden_dims,
            dropout_rates=classifier_dropout_rates,
            num_classes=num_classes
        )
    
    def forward(self, x_enc, x_mark_enc, mask):
        """
        前向传播 - 兼容版本
        
        Args:
            x_enc: 输入序列 [batch_size, seq_len, enc_in]
            x_mark_enc: 时间标记 [batch_size, seq_len, time_features]
            x_dec: decoder输入（忽略，为了兼容性）
            x_mark_dec: decoder时间标记（忽略，为了兼容性）
            enc_self_mask: 注意力掩码
        
        Returns:
            分类结果
        """
        # 通过编码器
        if self.output_attention:
            encoder_output, attns = self.encoder(x_enc, x_mark_enc, mask)
        else:
            encoder_output = self.encoder(x_enc, x_mark_enc, mask)
            attns = None
        
        # 通过分类器
        logits = self.classifier(encoder_output)
        
        if self.output_attention:
            return logits, attns
        else:
            return logits
    
    def extract_features(self, x_enc, x_mark_enc, mask):
        """
        提取编码器特征
        """
        encoder_output = self.encoder(x_enc, x_mark_enc, mask)
        return encoder_output
    
    def predict_proba(self, x_enc, x_mark_enc, mask):
        """
        预测概率
        """
        logits = self.forward(x_enc, x_mark_enc, mask)
        
        # 处理可能的元组返回
        if isinstance(logits, tuple):
            logits = logits[0]
        
        if self.num_classes == 2:
            probabilities = torch.sigmoid(logits)
        else:
            probabilities = F.softmax(logits, dim=-1)
        
        return probabilities
    
    def predict_class(self, x_enc, x_mark_enc, mask, threshold=0.5):
        """
        预测类别
        """
        probabilities = self.predict_proba(x_enc, x_mark_enc, mask)
        
        if self.num_classes == 2:
            predictions = (probabilities > threshold).long()
        else:
            predictions = torch.argmax(probabilities, dim=-1)
        
        return predictions
        
class InformerStack(nn.Module):
    def __init__(self, enc_in, dec_in, c_out, seq_len, label_len, out_len, 
                factor=5, d_model=512, n_heads=8, e_layers=[3,2,1], d_layers=2, d_ff=512, 
                dropout=0.0, attn='prob', embed='fixed', freq='h', activation='gelu',
                output_attention = False, distil=True, mix=True,
                device=torch.device('cuda:0')):
        super(InformerStack, self).__init__()
        self.pred_len = out_len
        self.attn = attn
        self.output_attention = output_attention

        # Encoding
        self.enc_embedding = DataEmbedding(enc_in, d_model, embed, freq, dropout)
        self.dec_embedding = DataEmbedding(dec_in, d_model, embed, freq, dropout)
        # Attention
        Attn = ProbAttention if attn=='prob' else FullAttention
        # Encoder

        inp_lens = list(range(len(e_layers))) # [0,1,2,...] you can customize here
        encoders = [
            Encoder(
                [
                    EncoderLayer(
                        AttentionLayer(Attn(False, factor, attention_dropout=dropout, output_attention=output_attention), 
                                    d_model, n_heads, mix=False),
                        d_model,
                        d_ff,
                        dropout=dropout,
                        activation=activation
                    ) for l in range(el)
                ],
                [
                    ConvLayer(
                        d_model
                    ) for l in range(el-1)
                ] if distil else None,
                norm_layer=torch.nn.LayerNorm(d_model)
            ) for el in e_layers]
        self.encoder = EncoderStack(encoders, inp_lens)
        # Decoder
        self.decoder = Decoder(
            [
                DecoderLayer(
                    AttentionLayer(Attn(True, factor, attention_dropout=dropout, output_attention=False), 
                                d_model, n_heads, mix=mix),
                    AttentionLayer(FullAttention(False, factor, attention_dropout=dropout, output_attention=False), 
                                d_model, n_heads, mix=False),
                    d_model,
                    d_ff,
                    dropout=dropout,
                    activation=activation,
                )
                for l in range(d_layers)
            ],
            norm_layer=torch.nn.LayerNorm(d_model)
        )
        # self.end_conv1 = nn.Conv1d(in_channels=label_len+out_len, out_channels=out_len, kernel_size=1, bias=True)
        # self.end_conv2 = nn.Conv1d(in_channels=d_model, out_channels=c_out, kernel_size=1, bias=True)
        self.projection = nn.Linear(d_model, c_out, bias=True)
        
    def forward(self, x_enc, x_mark_enc, x_dec, x_mark_dec, 
                enc_self_mask=None, dec_self_mask=None, dec_enc_mask=None):
        enc_out = self.enc_embedding(x_enc, x_mark_enc)
        enc_out, attns = self.encoder(enc_out, attn_mask=enc_self_mask)

        dec_out = self.dec_embedding(x_dec, x_mark_dec)
        dec_out = self.decoder(dec_out, enc_out, x_mask=dec_self_mask, cross_mask=dec_enc_mask)
        dec_out = self.projection(dec_out)
        
        # dec_out = self.end_conv1(dec_out)
        # dec_out = self.end_conv2(dec_out.transpose(2,1)).transpose(1,2)
        if self.output_attention:
            return dec_out[:,-self.pred_len:,:], attns
        else:
            return dec_out[:,-self.pred_len:,:] # [B, L, D]
            
